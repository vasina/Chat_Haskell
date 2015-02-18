import Network
import System.IO
import Control.Monad
import System.Environment
import Control.Concurrent

main = withSocketsDo $ do
       [host,portServerArg] <- getArgs
       putStrLn "Try to connect to the chat server..."
       handleReceive <- connectTo host (PortNumber (fromIntegral (read portServerArg :: Integer))) 
       putStrLn "Connected!"
       forkIO (sendMessage handleReceive)
       receiveMessage handleReceive       
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