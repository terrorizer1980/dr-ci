{-# LANGUAGE OverloadedStrings #-}

module Scanning where

import qualified Control.Exception          as E
import           Control.Lens               hiding ((<.>))
import           Control.Monad              (unless)
import           Data.Aeson                 (Value, decode, encode)
import           Data.Aeson.Lens            (key, _Array, _Bool, _Integral,
                                             _String)
import qualified Data.ByteString.Char8      as BSC
import qualified Data.ByteString.Lazy       as LBS

import           Data.Fixed                 (Fixed (MkFixed))
import           Data.Foldable              (for_)
import           Data.List                  (intercalate)
import           Data.Maybe                 (Maybe)
import qualified Data.Maybe                 as Maybe
import qualified Data.Text                  as T
import qualified Data.Text.Internal.Search  as Search
import qualified Data.Text.IO               as TIO
import           Data.Time                  (UTCTime)
import qualified Data.Time.Clock            as Clock
import qualified Data.Vector                as V
import           Database.PostgreSQL.Simple (Connection)
import           GHC.Int                    (Int64)
import           Network.HTTP.Client
import           Network.Wreq               as NW
import qualified Network.Wreq.Session       as Sess
import qualified Safe
import           System.Directory           (createDirectoryIfMissing,
                                             doesFileExist)
import           System.FilePath
import           Text.Regex.Base
import           Text.Regex.PCRE            ((=~~))

import qualified ScanCatchupResources
import           Builds
import qualified Constants
import qualified DbHelpers
import qualified ScanPatterns
import           SillyMonoids               ()
import qualified SqlRead
import qualified SqlWrite


maxBuildPerPage :: Int
maxBuildPerPage = 100


updateBuildsList :: Connection -> Int -> Int -> IO Int64
updateBuildsList conn fetch_count age_days = do
  putStrLn "Fetching builds list..."
  downloaded_builds_list <- Scanning.populate_builds fetch_count age_days

  putStrLn "Storing builds list..."
  SqlWrite.store_builds_list conn downloaded_builds_list


itemToBuild :: Value -> Build
itemToBuild json = NewBuild {
    build_id = NewBuildNumber $ view (key "build_num" . _Integral) json
  , vcs_revision = view (key "vcs_revision" . _String) json
  , queued_at = head $ Maybe.fromJust $ decode (encode [queued_at_string])
  , job_name = view (key "workflows" . key "job_name" . _String) json
  , branch = view (key "branch" . _String) json
  }
  where
    queued_at_string = view (key "queued_at" . _String) json


get_single_build_url :: BuildNumber -> String
get_single_build_url (NewBuildNumber build_number) = intercalate "/"
  [ Constants.circleci_api_base
  , show build_number
  ]


get_build_list_url :: String -> String
get_build_list_url branch_name = intercalate "/"
  [ Constants.circleci_api_base
  , "tree"
  , branch_name
  ]



get_step_failure :: Value -> Either BuildStepFailure ()
get_step_failure step_val =
  mapM_ get_failure my_array
  where
    my_array = step_val ^. key "actions" . _Array
    stepname = step_val ^. key "name" . _String

    step_fail = Left . NewBuildStepFailure stepname

    get_failure x
      | (x ^. key "failed" . _Bool) = step_fail $
          ScannableFailure $ NewBuildFailureOutput $ x ^. key "output_url" . _String
      | (x ^. key "timedout" . _Bool) = step_fail BuildTimeoutFailure
      | otherwise = pure ()


get_console_url :: (BuildNumber, Maybe BuildStepFailure) -> Maybe (BuildNumber, BuildFailureOutput)
get_console_url (build_number, maybe_thing) = case maybe_thing of
  Nothing -> Nothing
  Just (NewBuildStepFailure _stepname mode) -> case mode of
      BuildTimeoutFailure             -> Nothing
      ScannableFailure failure_output -> Just (build_number, failure_output)


prepare_scan_resources :: Connection -> IO ScanRecords.ScanCatchupResources
prepare_scan_resources conn = do

  aws_sess <- Sess.newSession
  circle_sess <- Sess.newSession

  cache_dir <- Constants.get_url_cache_basedir
  createDirectoryIfMissing True cache_dir

  pattern_records <- SqlRead.get_patterns conn
  let patterns_by_id = DbHelpers.to_dict pattern_records

  return $ ScanRecords.ScanCatchupResources
    conn
    aws_sess
    circle_sess
    patterns_by_id



catchup_scan :: ScanRecords.ScanCatchupResources -> Maybe String -> IO ()
catchup_scan scan_resources maybe_aws_link = do
  
  scannable_build_patterns <- SqlRead.get_unscanned_build_patterns conn patterns_by_id


  matches <- mapM (scan_log latest_pattern_id) scannable

  mapM_ (SqlWrite.store_matches conn scan_id) matches




-- | This function stores a record to the database
-- immediately upon build visitation. We do this instead of waiting
-- until the end so that we can resume progress if the process is
-- interrupted.
--
-- TODO We may want to interleave the console log downloads from AWS
-- with the build details visitations from CircleCI.
process_builds ::  -> [BuildNumber] -> IO ()
process_builds scan_resources unvisited_builds_list = do


  latest_pattern_id <- SqlRead.get_latest_pattern_id conn
  scan_id <- SqlWrite.insert_scan_id conn latest_pattern_id

  
  let unvisited_count = length unvisited_builds_list
  for_ (zip [1::Int ..] unvisited_builds_list) $ \(idx, build_num) -> do
    putStrLn $ "Visiting " ++ show idx ++ "/" ++ show unvisited_count ++ " builds..."
    result <- Scanning.get_failed_build_info sess build_num
    let foo = case result of
          Right _ -> Nothing
          Left x  -> Just x

        pair = (build_num, foo)

    case get_console_url pair of
      Nothing        -> return ()
      Just something -> Scanning.store_log sess something

    SqlWrite.insert_build_visitation conn pair



safeGetUrl ::
     IO (Response LBS.ByteString)
  -> IO (Either String (Response LBS.ByteString))
safeGetUrl f = do
  (Right <$> f) `E.catch` handler
  where
    handler :: HttpException -> IO (Either String (Response LBS.ByteString))
    handler (HttpExceptionRequest _ (StatusCodeException r _)) =
      return $ Left $ BSC.unpack (r ^. NW.responseStatus . statusMessage)
    handler x =
      return $ Left $ show x



-- | Determines which step of the build failed and stores
-- the console log to disk, if there is one.
get_failed_build_info :: Sess.Session -> BuildNumber -> IO (Either BuildStepFailure ())
get_failed_build_info sess build_number = do

  putStrLn $ "Fetching from: " ++ fetch_url

  either_r <- safeGetUrl $ Sess.getWith opts sess fetch_url

  case either_r of
    Right r -> do
      let steps_list = r ^. NW.responseBody . key "steps" . _Array

      return $ mapM_ get_step_failure steps_list
    Left err_message -> do
      putStrLn $ "PROBLEM: Failed in get_failed_build_info with message: " ++ err_message
      return $ Right ()

  where
    fetch_url = get_single_build_url build_number
    opts = defaults & header "Accept" .~ [Constants.json_mime_type]


get_single_build_list :: Sess.Session -> Int -> Int -> IO [Build]
get_single_build_list sess limit offset = do

  either_r <- safeGetUrl $ Sess.getWith opts sess fetch_url

  case either_r of
    Right r -> do

      let inner_list = r ^. NW.responseBody . _Array
          builds_list = map itemToBuild $ V.toList inner_list

      return builds_list
    Left err_message -> do
      putStrLn $ "PROBLEM: Failed in get_single_build_list with message: " ++ err_message
      return []

  where
    fetch_url = get_build_list_url "master"
    opts = defaults
      & header "Accept" .~ [Constants.json_mime_type]
      & param "shallow" .~ ["true"]
      & param "filter" .~ ["failed"]
      & param "offset" .~ [T.pack $ show offset]
      & param "limit" .~ [T.pack $ show limit]


populate_builds :: Int -> Int -> IO [Build]
populate_builds max_build_count max_age_days = do

  sess <- Sess.newSession
  current_time <- Clock.getCurrentTime
  let seconds_per_day = Clock.nominalDiffTimeToSeconds $ Clock.nominalDay
      seconds_offset = seconds_per_day * (MkFixed $ fromIntegral max_age_days)
      time_diff = Clock.secondsToNominalDiffTime seconds_offset
      earliest_requested_time = Clock.addUTCTime time_diff current_time
  populate_builds_recurse sess 0 earliest_requested_time max_build_count


populate_builds_recurse :: Sess.Session -> Int -> UTCTime -> Int -> IO [Build]
populate_builds_recurse sess offset earliest_requested_time max_build_count = do

  if max_build_count > 0
    then do

      putStrLn $ unwords [
          "Getting builds starting at"
        , show offset
        , "(" ++ show max_build_count ++ " left)"
        ]

      builds <- get_single_build_list sess builds_per_page offset

      let fetched_build_count = length builds
          builds_left = max_build_count - fetched_build_count

      case Safe.minimumMay $ map Builds.queued_at builds of
        Nothing ->
          putStrLn "No builds found."
        Just earliest_build_time ->
          putStrLn $ "Earliest build time found: " ++ show earliest_build_time

      let next_offset = offset + fetched_build_count
      more_builds <- populate_builds_recurse sess next_offset earliest_requested_time builds_left
      return $ builds ++ more_builds

  else
    return []

  where
    builds_per_page = min maxBuildPerPage max_build_count


-- TODO - these are methods of parallelization:



--  pages <- withTaskGroup 4 $ \g -> mapConcurrently g Scanning.store_log scannable
--  pages <- mapConcurrently Scanning.store_log scannable

--  pages <- withPool 1 $ \pool -> parallel_ pool $ map Scanning.store_log scannable


gen_log_path :: BuildNumber -> IO FilePath
gen_log_path (NewBuildNumber build_num) = do
  cache_dir <- Constants.get_url_cache_basedir
  return $ cache_dir </> filename_stem <.> "log"
  where
    filename_stem = show build_num


store_log :: Sess.Session -> (BuildNumber, BuildFailureOutput) -> IO ()
store_log sess (build_number, failed_build_output) = do

  full_filepath <- gen_log_path build_number

  -- We normally shouldn't even need to perform this check, because upstream we've already
  -- filtered out pre-cached build logs via the SQL query.
  -- HOWEVER, the existence check at this layer is still useful for when the database is wiped (for development).
  is_file_existing <- doesFileExist full_filepath

  putStrLn $ "Does log exist at path " ++ full_filepath ++ "? " ++ show is_file_existing

  unless is_file_existing $ do

      putStrLn $ "Log not on disk. Downloading from: " ++ T.unpack download_url

      either_r <- safeGetUrl $ Sess.get sess $ T.unpack download_url

      case either_r of
        Right r -> do
          let parent_elements = r ^. NW.responseBody . _Array
              console_log = (V.head parent_elements) ^. key "message" . _String

          TIO.writeFile full_filepath console_log
        Left err_message -> do
          putStrLn $ "PROBLEM: Failed in store_log with message: " ++ err_message
          return ()

  where
    download_url = log_url failed_build_output


scan_log ::
     SqlRead.PatternId
  -> SqlRead.ScanScope
  -> IO (SqlRead.ScanScope, [ScanPatterns.ScanMatch])
scan_log _latest_patern_id scan_scope = do

  full_filepath <- gen_log_path $ SqlRead.build_number scan_scope
  putStrLn $ "Scanning log: " ++ full_filepath

  console_log <- TIO.readFile full_filepath
  let result = filter (not . null) $ map apply_patterns $ zip [0..] $ map T.stripEnd $ T.lines console_log
  return (scan_scope, concat result)

  where
    apply_patterns line_tuple = Maybe.mapMaybe (apply_single_pattern line_tuple) $ SqlRead.unscanned_patterns scan_scope

    apply_single_pattern (line_number, line) db_pattern = match_partial <$> match_span
      where

        match_span = case ScanPatterns.expression pattern_obj of
          ScanPatterns.RegularExpression regex_text -> case ((T.unpack line) =~~ regex_text :: Maybe (MatchOffset, MatchLength)) of
            Just (match_offset, match_length) -> Just $ ScanPatterns.NewMatchSpan match_offset (match_offset + match_length)
            Nothing -> Nothing
          ScanPatterns.LiteralExpression literal_text -> case Safe.headMay (Search.indices literal_text line) of
            Just first_index -> Just $ ScanPatterns.NewMatchSpan first_index (first_index + T.length literal_text)
            Nothing -> Nothing

        match_partial x = ScanPatterns.NewScanMatch db_pattern $ ScanPatterns.NewMatchDetails line line_number x
        pattern_obj = DbHelpers.record db_pattern
