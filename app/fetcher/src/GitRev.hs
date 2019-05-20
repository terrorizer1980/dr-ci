{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module GitRev (GitSha1, validateSha1, sha1) where

import           Control.Monad (when)
import           Data.Char     (isHexDigit)
import           Data.Text     (Text)
import qualified Data.Text     as T


newtype GitSha1 = NewGitSha1 {
    sha1 :: Text
  }


validateSha1 :: Text -> Either Text GitSha1
validateSha1 sha1_text = do
  when (sha1_length /= 40) $
    Left $ "Improper sha1 length of " <> T.pack (show sha1_length)

  case maybe_non_hex_char of
    Nothing -> Right $ NewGitSha1 lowercase_sha1
    Just nonhex_char -> Left $ "Invalid hexadecimal digit: \"" <> T.singleton nonhex_char <> "\""

  where
    lowercase_sha1 = T.toLower sha1_text
    sha1_length = T.length sha1_text
    maybe_non_hex_char = T.find (not . isHexDigit) sha1_text
