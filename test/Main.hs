{-# language BangPatterns #-}
{-# language NamedFieldPuns #-}
{-# language ScopedTypeVariables #-}

import Control.Concurrent (forkIO)
import Control.Concurrent (threadWaitRead,threadWaitWrite)
import Control.Monad (when)
import Data.Primitive (ByteArray)
import Data.Word (Word32)
import Foreign.C.Error (Errno,errnoToIOError)
import Foreign.C.Types (CInt,CSize)
import Test.Tasty
import Test.Tasty.HUnit

import qualified GHC.Exts as E
import qualified Data.Primitive as PM
import qualified Data.Primitive.MVar as PM
import qualified Posix.Socket as S
import qualified Linux.Socket as L

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "tests"
  [ testGroup "posix"
    [ testGroup "sockets"
      [ testCase "A" testSocketsA
      , testCase "B" testSocketsB
      , testCase "C" testSocketsC
      , testCase "D" testSocketsD
      , testCase "E" testSocketsE
      , testCase "F" testSocketsF
      ]
    ]
  , testGroup "linux"
    [ testGroup "sockets"
      [ testCase "A" testLinuxSocketsA
      , testCase "B" testLinuxSocketsB
      ]
    ]
  ]

testSocketsA :: Assertion
testSocketsA = do
  (a,b) <- demand =<< S.uninterruptibleSocketPair S.unix S.datagram S.defaultProtocol
  m <- PM.newEmptyMVar
  _ <- forkIO $ S.receiveByteArray b 5 mempty >>= PM.putMVar m
  bytesSent <- demand =<< S.sendByteArray a sample 0 5 mempty
  when (bytesSent /= 5) (fail "testSocketsA: bytesSent was wrong")
  actual <- demand =<< PM.takeMVar m
  sample @=? actual

testSocketsB :: Assertion
testSocketsB = do
  let limit = 10
      wordSz = PM.sizeOf (undefined :: Int)
      cwordSz = fromIntegral wordSz :: CSize
  (a,b) <- demand =<< S.uninterruptibleSocketPair S.unix S.datagram S.defaultProtocol
  lock <- PM.newEmptyMVar
  let go1 !(ix :: Int) !(n :: Int) = if (ix < limit)
        then do
          y <- PM.newByteArray wordSz
          PM.writeByteArray y 0 (1 + n)
          z <- PM.unsafeFreezeByteArray y
          oneWord =<< demand =<< S.sendByteArray b z 0 cwordSz mempty
          x <- demand =<< S.receiveByteArray b cwordSz mempty
          go1 (ix + 1) (PM.indexByteArray x 0)
        else pure n
      go2 !(ix :: Int) = if (ix < limit)
        then do
          x <- demand =<< S.receiveByteArray a cwordSz mempty
          y <- PM.newByteArray wordSz
          PM.writeByteArray y 0 (1 + PM.indexByteArray x 0 :: Int) 
          z <- PM.unsafeFreezeByteArray y
          oneWord =<< demand =<< S.sendByteArray a z 0 cwordSz mempty
          go2 (ix + 1)
        else PM.putMVar lock ()
  _ <- forkIO (go2 0)
  r <- go1 0 0
  PM.takeMVar lock
  20 @=? r

testSocketsC :: Assertion
testSocketsC = do
  (a,b) <- demand =<< S.uninterruptibleSocketPair S.unix S.datagram S.defaultProtocol
  m <- PM.newEmptyMVar
  _ <- forkIO $ S.receiveByteArray a 5 mempty >>= PM.putMVar m
  bytesSent <- demand =<< S.sendByteArray b sample 0 5 mempty
  when (bytesSent /= 5) (fail "testSocketsC: bytesSent was wrong")
  actual <- demand =<< PM.takeMVar m
  sample @=? actual

testSocketsD :: Assertion
testSocketsD = do
  (a,b) <- demand =<< S.uninterruptibleSocketPair S.unix S.datagram S.defaultProtocol
  _ <- forkIO $ do
    bytesSent <- demand =<< S.sendByteArray b sample 0 5 mempty
    when (bytesSent /= 5) (fail "testSocketsD: bytesSent was wrong")
  actual <- demand =<< S.receiveByteArray a 5 mempty
  sample @=? actual

testSocketsE :: Assertion
testSocketsE = do
  (a,b) <- demand =<< S.uninterruptibleSocketPair S.unix S.datagram S.defaultProtocol
  _ <- forkIO $ do
    threadWaitWrite b
    bytesSent <- demand =<< S.uninterruptibleSendByteArray b sample 0 5 mempty
    when (bytesSent /= 5) (fail "testSocketsE: bytesSent was wrong")
  threadWaitRead a
  actual <- demand =<< S.uninterruptibleReceiveMessageA a 3 10 mempty
  (5,E.fromList [E.fromList [1,2,3],E.fromList [4,5]]) @=? actual

testSocketsF :: Assertion
testSocketsF = do
  a <- demand =<< S.uninterruptibleSocket S.internet S.datagram S.defaultProtocol
  demand =<< S.uninterruptibleBind a (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = 0, S.address = localhost}))
  (expectedSzA,expectedSockAddrA) <- demand =<< S.uninterruptibleGetSocketName a 128
  when (expectedSzA > 128) (fail "testSocketsF: bad socket address size for socket A")
  portA <- case S.decodeSocketAddressInternet expectedSockAddrA of
    Nothing -> fail "testSocketsF: not a sockaddr_in"
    Just (S.SocketAddressInternet {S.port}) -> pure port
  b <- demand =<< S.uninterruptibleSocket S.internet S.datagram S.defaultProtocol
  demand =<< S.uninterruptibleBind b (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = 0, S.address = localhost}))
  threadWaitWrite b
  bytesSent <- demand =<< S.uninterruptibleSendToByteArray b sample 0 5 mempty (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = portA, S.address = localhost}))
  when (bytesSent /= 5) (fail "testSocketsF: bytesSent was wrong")
  threadWaitRead a
  actual <- demand =<< S.uninterruptibleReceiveMessageB a 5 2 mempty 128
  (expectedSzB,expectedSockAddrB) <- demand =<< S.uninterruptibleGetSocketName b 128
  when (expectedSzB > 128) (fail "testSocketsF: bad socket address size for socket B")
  (expectedSzB,expectedSockAddrB,5,E.fromList [sample]) @=? actual


testLinuxSocketsA :: Assertion
testLinuxSocketsA = do
  (a,b) <- demand =<< S.uninterruptibleSocketPair S.unix S.datagram S.defaultProtocol
  threadWaitWrite b
  bytesSent1 <- demand =<< S.uninterruptibleSendByteArray b sample 0 5 mempty
  threadWaitWrite b
  bytesSent2 <- demand =<< S.uninterruptibleSendByteArray b sample2 0 4 mempty
  when (bytesSent1 /= 5) (fail "testLinuxSocketsA: bytesSent1 was wrong")
  when (bytesSent2 /= 4) (fail "testLinuxSocketsA: bytesSent2 was wrong")
  threadWaitRead a
  actual <- demand =<< L.uninterruptibleReceiveMultipleMessageA a 6 3 L.dontWait
  (5,E.fromList [sample,sample2]) @=? actual

testLinuxSocketsB :: Assertion
testLinuxSocketsB = do
  a <- demand =<< S.uninterruptibleSocket S.internet S.datagram S.defaultProtocol
  demand =<< S.uninterruptibleBind a (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = 0, S.address = localhost}))
  (expectedSzA,expectedSockAddrA) <- demand =<< S.uninterruptibleGetSocketName a 128
  when (expectedSzA /= S.sizeofSocketAddressInternet) (fail "testLinixSocketsB: bad socket address size for socket A")
  portA <- case S.decodeSocketAddressInternet expectedSockAddrA of
    Nothing -> fail "testLinixSocketsB: not a sockaddr_in"
    Just (S.SocketAddressInternet {S.port}) -> pure port
  b <- demand =<< S.uninterruptibleSocket S.internet S.datagram S.defaultProtocol
  demand =<< S.uninterruptibleBind b (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = 0, S.address = localhost}))
  threadWaitWrite b
  bytesSent1 <- demand =<< S.uninterruptibleSendToByteArray b sample 0 5 mempty (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = portA, S.address = localhost}))
  when (bytesSent1 /= 5) (fail "testLinixSocketsB: bytesSent1 was wrong")
  threadWaitWrite b
  bytesSent2 <- demand =<< S.uninterruptibleSendToByteArray b sample2 0 4 mempty (S.encodeSocketAddressInternet (S.SocketAddressInternet {S.port = portA, S.address = localhost}))
  when (bytesSent2 /= 4) (fail "testLinixSocketsB: bytesSent2 was wrong")
  threadWaitRead a
  actual <- demand =<< L.uninterruptibleReceiveMultipleMessageB a S.sizeofSocketAddressInternet 6 3 L.dontWait
  (expectedSzB,S.SocketAddress sabytesB) <- demand =<< S.uninterruptibleGetSocketName b 128
  when (expectedSzB /= S.sizeofSocketAddressInternet) (fail "testLinixSocketsB: bad socket address size for socket B")
  (0,sabytesB <> sabytesB,5,E.fromList [sample,sample2]) @=? actual

sample :: ByteArray
sample = E.fromList [1,2,3,4,5]

sample2 :: ByteArray
sample2 = E.fromList [6,7,8,9]

demand :: Either Errno a -> IO a
demand = either (\e -> ioError (errnoToIOError "test" e Nothing Nothing)) pure
  
oneWord :: CSize -> IO ()
oneWord x = if x == fromIntegral (PM.sizeOf (undefined :: Int)) then pure () else fail "expected one machine word"

localhost :: Word32
localhost = S.hostToNetworkLong 2130706433

