{-# LANGUAGE OverloadedStrings #-}

module Constants where

import           Data.ByteString (ByteString)
import           Data.List       (intercalate)
import           Data.Text       (Text)

import qualified AuthConfig
import qualified AuthStages
import qualified CircleApi
import qualified DbHelpers


pytorchRepoOwner :: DbHelpers.OwnerAndRepo
pytorchRepoOwner = DbHelpers.OwnerAndRepo projectName repoName


data ProviderConfigs = ProviderConfigs {
    github_config     :: AuthConfig.GithubConfig
  , third_party_creds :: CircleApi.ThirdPartyAuth
  , database_config   :: DbHelpers.DbConnectionData
  }


printDebug :: Bool
printDebug = True


masterName :: Text
masterName = "master"


gitCommitPrefixLength :: Int
gitCommitPrefixLength = 10


defaultPatternAuthor :: AuthStages.Username
defaultPatternAuthor = AuthStages.Username "kostmo"


gitHubAppId :: Int
gitHubAppId = 30634


pytorchGitHubAppInstallationId :: Int
pytorchGitHubAppInstallationId = 1001398



-- | Not used
appName :: FilePath
appName = "circleci-failure-tracker"


jsonMimeType :: ByteString
jsonMimeType = "application/json"


projectName :: String
projectName = "pytorch"


repoName :: String
repoName = "pytorch"


pytorchOwnedRepo :: DbHelpers.OwnerAndRepo
pytorchOwnedRepo = DbHelpers.OwnerAndRepo
  projectName
  repoName


circleciApiBase :: String
circleciApiBase = intercalate "/"
  [ "https://circleci.com/api/v1.1/project/github"
  , projectName
  , repoName
  ]


