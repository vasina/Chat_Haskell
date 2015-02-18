import Network
import System.IO
import Control.Monad
import System.Environment
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import System.IO.Error

main = withSocketsDo $ do
       [host,portServerArg] <- getArgs
       putStrLn " "
       putStrLn "Try to connect to the chat server..."
       putStrLn " "
       handleReceive <- connectTo host (PortNumber (fromIntegral (read portServerArg :: Integer)))
       putStrLn "Connected!"
       race ((receiveMessage handleReceive) `catch` handler) (sendMessage handleReceive)
       hClose handleReceive
       return ()

receiveMessage :: Handle -> IO ()
receiveMessage handle = forever $ do
       hSetBuffering handle NoBuffering
       msg <- hGetLine handle
       putStrLn msg

sendMessage :: Handle -> IO ()
sendMessage handle = forever $ do
       line <- getLine
       hPutStrLn handle line

handler :: IOError -> IO ()
handler e =  putStrLn " \nWhoops, had some trouble!"
	   
--------------------------------------------------------------------

-- implementation of race function
--race to create the two threads with a sibling relationship 
--so that if either thread returns or fails, the other will be cancelled

data Async a = Async ThreadId (TMVar (Either SomeException a))

async :: IO a -> IO (Async a)
async action = do
  var <- newEmptyTMVarIO
  t <- forkFinally action (atomically . putTMVar var)
  return (Async t var)

waitCatchSTM :: Async a -> STM (Either SomeException a)
waitCatchSTM (Async _ var) = readTMVar var

waitSTM :: Async a -> STM a
waitSTM a = do
  r <- waitCatchSTM a
  case r of
    Left e  -> throwSTM e
    Right a -> return a

waitEither :: Async a -> Async b -> IO (Either a b)
waitEither a b = atomically $
  fmap Left (waitSTM a)
    `orElse`
  fmap Right (waitSTM b)

cancel :: Async a -> IO ()
cancel (Async t var) = throwTo t ThreadKilled

withAsync :: IO a -> (Async a -> IO b) -> IO b
withAsync io operation = bracket (async io) cancel operation

race :: IO a -> IO b -> IO (Either a b)
race ioa iob =
  withAsync ioa $ \a ->
  withAsync iob $ \b ->
    waitEither a b
-------------------------------------------------------------------