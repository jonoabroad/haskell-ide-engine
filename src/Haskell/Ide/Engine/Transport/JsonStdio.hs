{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
-- |Provide a protocol adapter/transport for JSON over stdio

module Haskell.Ide.Engine.Transport.JsonStdio where

import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import           Control.Lens (view)
import           Data.Aeson
import           Control.Monad.IO.Class
import           Control.Monad.STM
import           Control.Monad.State.Strict
import qualified Data.Attoparsec.ByteString as AB
import qualified Data.Attoparsec.ByteString.Char8 as AB
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import           Data.Char
import qualified Data.Map as Map
import qualified Data.Text as T
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.Types
import qualified Pipes as P
import qualified Pipes.Aeson as PAe
import qualified Pipes.Attoparsec as PA
import qualified Pipes.ByteString as PB
import qualified Pipes.Prelude as P
import           System.IO

-- TODO: Can pass in a handle, then it is general
jsonStdioTransport :: Bool -> TChan ChannelRequest -> IO ()
jsonStdioTransport oneShot cin = do
  cout <- atomically $ newTChan :: IO (TChan ChannelResponse)
  hSetBuffering stdout NoBuffering
  _ <- forkIO $ P.runEffect (parseFrames PB.stdin P.>-> parseToJsonPipe oneShot cin cout 1)
  P.runEffect (tchanProducer oneShot cout P.>-> encodePipe P.>-> jsonConsumer)

parseToJsonPipe
  :: Bool
  -> TChan ChannelRequest
  -> TChan ChannelResponse
  -> Int
  -> P.Consumer (Either PAe.DecodingError WireRequest) IO ()
parseToJsonPipe oneShot cin cout cid =
  do parseRes <- P.await
     case parseRes of
       Left decodeErr ->
         do let rsp =
                  CResp "" cid $
                  IdeResponseError
                    (IdeError ParseError (T.pack $ show decodeErr) Null)
            liftIO $ debugm $ "jsonStdioTransport:parse error:" ++ show decodeErr
            liftIO $ atomically $ writeTChan cout rsp
       Right req ->
         do liftIO $ atomically $ writeTChan cin (wireToChannel cout cid req)
     unless oneShot $
         parseToJsonPipe False
                         cin
                         cout
                         (cid + 1)

jsonConsumer :: P.Consumer Value IO ()
jsonConsumer =
  do val <- P.await
     liftIO $ BL.putStr (encode val)
     liftIO $ BL.putStr (BL.singleton $ fromIntegral (ord '\STX'))
     jsonConsumer

tchanProducer :: MonadIO m => Bool -> TChan a -> P.Producer a m ()
tchanProducer oneShot chan = do
  val <- liftIO $ atomically $ readTChan chan
  P.yield val
  unless oneShot $ tchanProducer False chan

encodePipe :: P.Pipe ChannelResponse Value IO ()
encodePipe = P.map (toJSON . channelToWire)

parseFrames
  :: forall m.
     Monad m
  => P.Producer B.ByteString m ()
  -> P.Producer (Either PAe.DecodingError WireRequest) m ()
parseFrames prod0 = do
  -- if there are no more bytes, we just return ()
  (isEmpty, prod1) <- lift $ runStateT PB.isEndOfBytes prod0
  if isEmpty then return () else go prod1
  where
    -- ignore inputs consisting only of space
    terminatedJSON :: AB.Parser (Maybe Value)
    terminatedJSON = (fmap Just $ json' <* AB.many' AB.space <* AB.endOfInput)
                 <|> (AB.many' AB.space *> pure Nothing)
    -- endOfInput: we want to be sure that the given
    -- parser consumes the entirety of the given input
    go :: P.Producer B.ByteString m ()
       -> P.Producer (Either PAe.DecodingError WireRequest) m ()
    go prod = do
       let splitProd :: P.Producer B.ByteString m (P.Producer B.ByteString m ())
           splitProd = view (PB.break (== fromIntegral (ord '\STX'))) prod
       (maybeRet, leftoverProd) <- lift $ runStateT (PA.parse terminatedJSON) splitProd
       case maybeRet of
         Nothing -> return ()
         Just (ret) -> do
           let maybeWrappedRet :: Maybe (Either PAe.DecodingError WireRequest)
               maybeWrappedRet = case ret of
                                             Left parseErr -> pure $ Left $ PAe.AttoparsecError parseErr
                                             Right (Just a) -> case fromJSON a of
                                                                 Error err -> pure $ Left $ PAe.FromJSONError err
                                                                 Success wireReq -> pure $ Right wireReq
                                             Right Nothing -> Nothing
           case maybeWrappedRet of
             Just wrappedRet -> P.yield wrappedRet
             Nothing -> return ()
           -- leftoverProd is guaranteed to be empty by the use of A8.endOfInput in ap1
           newProd <- lift $ P.runEffect (leftoverProd P.>-> P.drain)
           -- recur into parseFrames to parse the next line, drop the leading '\n'
           parseFrames (PB.drop (1::Int) newProd)


-- to help with type inference
printTest :: (MonadIO m) => P.Consumer' [Int] m r
printTest = P.print

-- ---------------------------------------------------------------------

wireToChannel :: TChan ChannelResponse -> RequestId -> WireRequest -> ChannelRequest
wireToChannel cout ri wr =
  CReq
    { cinPlugin = plugin
    , cinReqId = ri
    , cinReq = IdeRequest
                 { ideCommand = T.tail command
                 , ideParams  = params wr
                 }
    , cinReplyChan = cout
    }
    where
      (plugin,command) = T.break (==':') (cmd wr)

-- ---------------------------------------------------------------------

channelToWire :: ChannelResponse -> WireResponse
channelToWire cr = WireResp $ toJSON $ coutResp cr

-- ---------------------------------------------------------------------

data WireRequest = WireReq
  { cmd     :: T.Text -- ^combination of PluginId ":" CommandName
  , params  :: ParamMap
  } deriving (Show,Eq)

instance ToJSON WireRequest where
    toJSON wr = object
                [ "cmd" .= cmd wr
                , "params" .= params wr
                ]


instance FromJSON WireRequest where
    parseJSON = withObject "WireRequest" $ \v ->
      WireReq <$>
      v .: "cmd" <*>
      v .:? "params" .!= Map.empty

-- ---------------------------------------------------------------------

data WireResponse = WireResp Value
                  deriving (Show,Eq)

instance ToJSON WireResponse where
    toJSON (WireResp val) = val


instance FromJSON WireResponse where
    parseJSON p = return $ WireResp p
