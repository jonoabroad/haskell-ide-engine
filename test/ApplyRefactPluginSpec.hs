{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}
module ApplyRefactPluginSpec where

import qualified Data.HashMap.Strict                   as H
import           Haskell.Ide.Engine.Plugin.ApplyRefact
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import           Language.Haskell.LSP.TH.DataTypesJSON
import           System.Directory
import           TestUtils

import           Test.Hspec

-- ---------------------------------------------------------------------

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "apply-refact plugin" applyRefactSpec

-- ---------------------------------------------------------------------

testPlugins :: IdePlugins
testPlugins = pluginDescToIdePlugins [("applyrefact",applyRefactDescriptor)]

-- ---------------------------------------------------------------------

applyRefactSpec :: Spec
applyRefactSpec = do
  describe "apply-refact plugin commands" $ do
    applyRefactPath  <- runIO $ filePathToUri <$> makeAbsolute "./test/testdata/ApplyRefact.hs"

    -- ---------------------------------

    it "applies one hint only" $ do

      let furi = filePathToUri "./test/testdata/ApplyRefact.hs"
          act = applyOneCmd' furi
                             (toPos (2,8))
          arg = AOP furi (toPos (2,8))
          res = IdeResponseOk $ WorkspaceEdit
            (Just $ H.singleton applyRefactPath
                                $ List [TextEdit (Range (Position 1 0) (Position 1 25))
                                          "main = putStrLn \"hello\""])
            Nothing
      testCommand testPlugins act "applyrefact" "applyOne" arg res

    -- ---------------------------------

    it "applies all hints" $ do

      let act = applyAllCmd' arg
          arg = filePathToUri "./test/testdata/ApplyRefact.hs"
          res = IdeResponseOk $ WorkspaceEdit
            (Just
              $ H.singleton applyRefactPath
                          $ List [TextEdit (Range (Position 1 0) (Position 1 25))
                                    "main = putStrLn \"hello\""
                                 ,TextEdit (Range (Position 3 0) (Position 3 15))
                                    "foo x = x + 1"])
            Nothing
      testCommand testPlugins act "applyrefact" "applyAll" arg res

    -- ---------------------------------

    it "returns hints as diagnostics" $ do

      let act = lintCmd' arg
          arg = filePathToUri "./test/testdata/ApplyRefact.hs"
          res = IdeResponseOk
            PublishDiagnosticsParams
             { _uri = filePathToUri "./test/testdata/ApplyRefact.hs"
             , _diagnostics = List $
               [ Diagnostic (Range (Position 1 7) (Position 1 25))
                            (Just DsHint)
                            Nothing
                            (Just "hlint")
                            "Redundant bracket\nFound:\n  (putStrLn \"hello\")\nWhy not:\n  putStrLn \"hello\"\n"
                            (List [])
               , Diagnostic (Range (Position 3 8) (Position 3 15))
                            (Just DsHint)
                            Nothing
                            (Just "hlint")
                            "Redundant bracket\nFound:\n  (x + 1)\nWhy not:\n  x + 1\n"
                            (List [])
               ]}
      testCommand testPlugins act "applyrefact" "lint" arg res

    -- ---------------------------------

    it "returns hlint parse error as DsInfo ignored diagnostic" $ do

      let act = lintCmd' arg
          arg = filePathToUri "./test/testdata/HlintParseFail.hs"
          res = IdeResponseOk
            PublishDiagnosticsParams
             { _uri = Uri {getUri = "file://./test/testdata/HlintParseFail.hs"}
             , _diagnostics = List $
               [Diagnostic {_range = Range { _start = Position {_line = 11, _character = 28}
                                           , _end = Position {_line = 11, _character = 100000}}
                           , _severity = Just DsInfo
                           , _code = Just "parser"
                           , _source = Just "hlint"
                           , _message = "Parse error: :~:\n  import           Data.Type.Equality            ((:~:) (..), (:~~:) (..))\n  \n> data instance Sing (z :: (a :~: b)) where\n      SRefl :: Sing Refl\n\n"
                           , _relatedInformation = List [] }]}
      testCommand testPlugins act "applyrefact" "lint" arg res

    -- ---------------------------------

    it "respects hlint pragmas in the source file" $ do

      let req = lintCmd' (filePathToUri "./test/testdata/HlintPragma.hs")
      r <- runIGM testPlugins req
      r `shouldBe`
        (IdeResponseOk
           (PublishDiagnosticsParams
            { _uri = filePathToUri "./test/testdata/HlintPragma.hs"
            , _diagnostics = List
              [ Diagnostic (Range (Position 3 11) (Position 3 20))
                           (Just DsInfo)
                           Nothing
                           (Just "hlint")
                           "Redundant bracket\nFound:\n  (\"hello\")\nWhy not:\n  \"hello\"\n"
                           (List [])
              ]
            }
           ))

    -- ---------------------------------

    it "respects hlint config files in project root dir" $ do

      let req = lintCmd' (filePathToUri "./HlintPragma.hs")
      r <- cdAndDo "./test/testdata" $ runIGM testPlugins req
      r `shouldBe`
        (IdeResponseOk
           (PublishDiagnosticsParams
            { _uri = filePathToUri "./HlintPragma.hs"
            , _diagnostics = List []
            }
           ))
