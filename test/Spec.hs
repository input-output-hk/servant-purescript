{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Control.Applicative
import Control.Exception (bracket, bracket_)
import Control.Lens
import Data.Aeson
import Data.Proxy
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text.IO as T
import Data.Typeable
import GHC.Generics
import Language.PureScript.Bridge
import Language.PureScript.Bridge.PSTypes
import Servant.API
import Servant.Foreign
import Servant.PureScript
import Servant.PureScript.CodeGen
import Servant.PureScript.Internal
import System.Directory (removeDirectoryRecursive, removeFile, withCurrentDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
import Test.HUnit (assertEqual)
import Test.Hspec (aroundAll_, describe, hspec, it)
import Test.Hspec.Expectations.Pretty (shouldBe)
import Text.PrettyPrint.Mainland (hPutDocLn)

newtype Hello = Hello
  { message :: Text
  }
  deriving (Generic, Eq, Ord)

instance FromJSON Hello

instance ToJSON Hello

newtype TestHeader = TestHeader Text deriving (Generic, Show, Eq)

instance ToJSON TestHeader

type MyAPI =
  Header "TestHeader" TestHeader :> QueryFlag "myFlag" :> QueryParam "myParam" Hello :> QueryParams "myParams" Hello :> "hello" :> ReqBody '[JSON] Hello :> Get '[JSON] Hello
    :<|> Header "TestHeader" Hello :> "testHeader" :> Get '[JSON] TestHeader
    :<|> Header "TestHeader" TestHeader :> "by" :> Get '[JSON] Int

reqs = apiToList (Proxy :: Proxy MyAPI) (Proxy :: Proxy DefaultBridge)

req = head reqs

mySettings = addReaderParam "TestHeader" defaultSettings

myTypes :: [SumType 'Haskell]
myTypes =
  [ equal <*> (order <*> (genericShow <*> mkSumType)) $ Proxy @Hello,
    mkSumType (Proxy :: Proxy TestHeader)
  ]

moduleTranslator :: BridgePart
moduleTranslator = do
  typeModule ^== "Main"
  t <- view haskType
  TypeInfo (_typePackage t) "ServerTypes" (_typeName t) <$> psTypeParameters

myBridge :: BridgePart
myBridge = defaultBridge <|> moduleTranslator

data MyBridge

instance HasBridge MyBridge where
  languageBridge _ = buildBridge myBridge

myBridgeProxy :: Proxy MyBridge
myBridgeProxy = Proxy

main :: IO ()
main = hspec $
  aroundAll_ withOutput $
    describe "output" $ do
      it "should match the golden tests for types" $ do
        expected <- T.readFile "ServerTypes.purs"
        actual <- T.readFile "ServerTypes.purs"
        actual `shouldBe` expected
      it "should match the golden tests for API" $ do
        expected <- T.readFile "ServerAPI.purs"
        actual <- T.readFile "ServerAPI.purs"
        actual `shouldBe` expected
      it "should be buildable" $ do
        (exitCode, stdout, stderr) <- readProcessWithExitCode "spago" ["build"] ""
        assertEqual stdout exitCode ExitSuccess
  where
    withOutput runSpec =
      withCurrentDirectory "test/output" $ bracket_ generate cleanup runSpec

    generate = do
      writeAPIModuleWithSettings mySettings "." myBridgeProxy (Proxy :: Proxy MyAPI)
      writePSTypes "." (buildBridge myBridge) myTypes

    cleanup = do
      removeFile "ServerTypes.purs"
      removeFile "ServerAPI.purs"
      removeDirectoryRecursive ".spago"
