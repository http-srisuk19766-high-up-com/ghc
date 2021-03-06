{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

-------------------------------------------------------------------------------
-- |
-- Module      :  GHC.Event.Windows.FFI
-- Copyright   :  (c) Tamar Christina 2019
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable
--
-- WinIO Windows API Foreign Function imports
--
-------------------------------------------------------------------------------

module GHC.Event.Windows.FFI (
    -- * IOCP
    IOCP(..),
    CompletionKey,
    newIOCP,
    associateHandleWithIOCP,
    getQueuedCompletionStatusEx,
    postQueuedCompletionStatus,
    getOverlappedResult,

    -- * Overlapped
    OVERLAPPED,
    LPOVERLAPPED,
    OVERLAPPED_ENTRY(..),
    LPOVERLAPPED_ENTRY,
    HASKELL_OVERLAPPED,
    LPHASKELL_OVERLAPPED,
    allocOverlapped,
    zeroOverlapped,
    pokeOffsetOverlapped,
    overlappedIOStatus,
    overlappedIONumBytes,

    -- * Cancel pending I/O
    cancelIoEx,
    cancelIoEx',

    -- * Monotonic time

    -- ** GetTickCount
    getTickCount64,

    -- ** QueryPerformanceCounter
    queryPerformanceCounter,
    queryPerformanceFrequency,

    -- ** Miscellaneous
    throwWinErr,
    setLastError
) where

#include <ntstatus.h>
#include <windows.h>
#include "winio_structs.h"

##include "windows_cconv.h"

import Data.Maybe
import Foreign
import GHC.Base
import GHC.Num ((*))
import GHC.Real (fromIntegral)
import GHC.Show
import GHC.Windows
import qualified GHC.Event.Array as A
import qualified GHC.Windows     as Win32
import GHC.IO.Handle.Internals (debugIO)

------------------------------------------------------------------------
-- IOCP

-- | An I/O completion port.
newtype IOCP = IOCP HANDLE
    deriving (Eq, Ord, Show)

type CompletionKey = ULONG_PTR

-- | This function has two distinct purposes depending on the value of
-- The completion port handle:
--
--  - When the IOCP port is NULL then the function creates a new I/O completion
--    port.  See `newIOCP`.
--
--  - When The port contains a valid handle then the given handle is
--    associated with he given completion port handle.  Once associated it
--    cannot be easily changed.  Associating a Handle with a Completion Port
--    allows the I/O manager's worker threads to handle requests to the given
--    handle.
foreign import WINDOWS_CCONV unsafe "windows.h CreateIoCompletionPort"
    c_CreateIoCompletionPort :: HANDLE -> IOCP -> ULONG_PTR -> DWORD
                             -> IO IOCP

-- | Create a new I/O completion port.
newIOCP :: IO IOCP
newIOCP = failIf (== IOCP nullPtr) "newIOCP" $
          c_CreateIoCompletionPort iNVALID_HANDLE_VALUE (IOCP nullPtr) 0 0

-- | Associate a HANDLE with an I/O completion port.
associateHandleWithIOCP :: IOCP -> HANDLE -> CompletionKey -> IO ()
associateHandleWithIOCP iocp handle completionKey =
    failIf_ (/= iocp) "associateHandleWithIOCP" $
        c_CreateIoCompletionPort handle iocp completionKey 0

foreign import WINDOWS_CCONV safe "windows.h GetOverlappedResult"
    c_GetOverlappedResult :: HANDLE -> LPOVERLAPPED -> Ptr DWORD -> BOOL
                          -> IO BOOL

-- | Get the result of a single overlap operation without the IO manager
getOverlappedResult :: HANDLE -> Ptr OVERLAPPED -> BOOL -> IO (Maybe DWORD)
getOverlappedResult handle lp block
  = alloca $ \bytes ->
        do res <- c_GetOverlappedResult handle lp bytes block
           if res
              then fmap Just $ peek bytes
              else return Nothing

foreign import WINDOWS_CCONV safe "windows.h GetQueuedCompletionStatusEx"
    c_GetQueuedCompletionStatusEx :: IOCP -> LPOVERLAPPED_ENTRY -> Word32
                                  -> Ptr ULONG -> DWORD -> BOOL -> IO BOOL

-- | Note [Completion Ports]
-- When an I/O operation has been queued by an operation
-- (ReadFile/WriteFile/etc) it is placed in a queue that the driver uses when
-- servicing IRQs.  This queue has some important properties:
--
-- 1.) It is not an ordered queue.  Requests may be performed out of order as
--     as the OS's native I/O manager may try to re-order requests such that as
--     few random seeks as possible are needed to complete the pending
--     operations.  As such do not assume a fixed order between something being
--     queued and dequeued.
--
-- 2.) Operations may skip the queue entirely.  In which case they do not end in
--     in this function. (This is an optimization flag we have turned on. See
--     `openFile`.)
--
-- 3.) Across this call the specified OVERLAPPED_ENTRY buffer MUST remain live,
--     and the buffer for an I/O operation cannot be freed or moved until
--     `getOverlappedResult` says it's done.  The reason is the kernel may not
--     have fully released the buffer, or finished writing to it when this
--     operation returns.  Failure to adhere to this will cause your IRQs to be
--     silently dropped and your program will never receive a completion for it.
--     This means that the OVERLAPPED buffer must also remain valid for the
--     duration of the call and as such must be allocated on the unmanaged heap.
--
-- 4.) When a thread calls this method it is associated with the I/O manager's
--     worker threads pool.  You should always use dedicated threads for this
--     since the OS I/O manager will now monitor the threads.  If the thread
--     becomes blocked for whatever reason, the Haskell I/O manager will wake up
--     another threads from it's pool to service the remaining results.
--     A new thread will also be woken up from the pool when the previous thread
--     is busy servicing requests and new requests have finished.  For this
--     reason the Haskell I/O manager multiplexes I/O operations from N haskell
--     threads into 1 completion port, which is serviced by M native threads in
--     an asynchronous method. This allows it to scale efficiently.
getQueuedCompletionStatusEx :: IOCP
                            -> A.Array OVERLAPPED_ENTRY
                            -> DWORD  -- ^ Timeout in milliseconds (or
                                      -- 'GHC.Windows.iNFINITE')
                            -> IO Int
getQueuedCompletionStatusEx iocp arr timeout =
    alloca $ \num_removed_ptr ->do
        A.unsafeLoad arr $ \oes cap -> do
            -- TODO: remove after debugging
            fillBytes oes 0 (cap * (sizeOf (undefined :: OVERLAPPED_ENTRY)))
            debugIO $ "-- call getQueuedCompletionStatusEx "
            -- don't block the call if the rts is not supporting threads.
            -- this would block the entire program.
            let alertable = False -- not rtsSupportsBoundThreads
            ok <- c_GetQueuedCompletionStatusEx iocp oes (fromIntegral cap)
                  num_removed_ptr timeout alertable
            debugIO $ "-- call getQueuedCompletionStatusEx: " ++ show ok
            err <- getLastError
            nc <- (peek num_removed_ptr)
            debugIO $ "-- getQueuedCompletionStatusEx: n=" ++ show nc ++ " ,err=" ++ show err
            if ok then fromIntegral `fmap` peek num_removed_ptr
            else do debugIO $ "failed getQueuedCompletionStatusEx: " ++ show err
                    if err == #{const WAIT_TIMEOUT} || alertable then return 0
                    else failWith "GetQueuedCompletionStatusEx" err

overlappedIOStatus :: LPOVERLAPPED -> IO NTSTATUS
overlappedIOStatus lpol = do
  status <- #{peek OVERLAPPED, Internal} lpol
  -- TODO: Map NTSTATUS to ErrCode?
  -- See https://github.com/libuv/libuv/blob/b12624c13693c4d29ca84b3556eadc9e9c0936a4/src/win/winsock.c#L153
  return status
{-# INLINE overlappedIOStatus #-}

overlappedIONumBytes :: LPOVERLAPPED -> IO ULONG_PTR
overlappedIONumBytes lpol = do
  bytes <- #{peek OVERLAPPED, InternalHigh} lpol
  return bytes
{-# INLINE overlappedIONumBytes #-}

foreign import WINDOWS_CCONV unsafe "windows.h PostQueuedCompletionStatus"
    c_PostQueuedCompletionStatus :: IOCP -> DWORD -> ULONG_PTR -> LPOVERLAPPED
                                 -> IO BOOL

-- | Manually post a completion to the specified I/O port.  This will wake up
-- a thread waiting `GetQueuedCompletionStatusEx`.
postQueuedCompletionStatus :: IOCP -> DWORD -> CompletionKey -> LPOVERLAPPED
                           -> IO ()
postQueuedCompletionStatus iocp numBytes completionKey lpol =
    failIfFalse_ "PostQueuedCompletionStatus" $
    c_PostQueuedCompletionStatus iocp numBytes completionKey lpol

------------------------------------------------------------------------
-- Overlapped

-- | Tag type for @LPOVERLAPPED@.
data OVERLAPPED

-- | Tag type for the extended version of @OVERLAPPED@ containg some book
--   keeping information.
data HASKELL_OVERLAPPED

-- | Identifies an I/O operation.  Used as the @LPOVERLAPPED@ parameter
-- for overlapped I/O functions (e.g. @ReadFile@, @WSASend@).
type LPOVERLAPPED = Ptr OVERLAPPED

-- | Pointer to the extended HASKELL_OVERLAPPED function.
type LPHASKELL_OVERLAPPED = Ptr HASKELL_OVERLAPPED

-- | An array of these is passed to GetQueuedCompletionStatusEx as an output
-- argument.
data OVERLAPPED_ENTRY = OVERLAPPED_ENTRY {
      lpCompletionKey            :: ULONG_PTR,
      lpOverlapped               :: LPOVERLAPPED,
      dwNumberOfBytesTransferred :: DWORD
    }

type LPOVERLAPPED_ENTRY = Ptr OVERLAPPED_ENTRY

instance Storable OVERLAPPED_ENTRY where
    sizeOf _    = #{size OVERLAPPED_ENTRY}
    alignment _ = #{alignment OVERLAPPED_ENTRY}

    peek ptr = do
      lpCompletionKey <- #{peek OVERLAPPED_ENTRY, lpCompletionKey} ptr
      lpOverlapped    <- #{peek OVERLAPPED_ENTRY, lpOverlapped} ptr
      dwNumberOfBytesTransferred <-
          #{peek OVERLAPPED_ENTRY, dwNumberOfBytesTransferred} ptr
      let !oe = OVERLAPPED_ENTRY{..}
      return oe

    poke ptr OVERLAPPED_ENTRY{..} = do
      #{poke OVERLAPPED_ENTRY, lpCompletionKey} ptr lpCompletionKey
      #{poke OVERLAPPED_ENTRY, lpOverlapped} ptr lpOverlapped
      #{poke OVERLAPPED_ENTRY, dwNumberOfBytesTransferred}
        ptr dwNumberOfBytesTransferred

-- | Allocate a new
-- <http://msdn.microsoft.com/en-us/library/windows/desktop/ms684342%28v=vs.85%29.aspx
-- OVERLAPPED> structure on the unmanaged heap. This also zeros the memory to
-- prevent the values inside the struct to be incorrectlt interpreted as data
-- payload.
--
-- We extend the overlapped structure with some extra book keeping information
-- such that we don't have to do a lookup on the Haskell side.
--
-- Future: We can gain some performance here by using a pool instead of calling
--         malloc for each request. A simple block allocator would be very
--         useful here, especially when we implement sockets support.
allocOverlapped :: Word64 -- ^ Offset/OffsetHigh
                -> IO (Ptr HASKELL_OVERLAPPED)
allocOverlapped offset = do
  lpol <- mallocBytes #{size HASKELL_OVERLAPPED}
  zeroOverlapped lpol
  pokeOffsetOverlapped (castPtr lpol) offset
  return lpol

-- | Zero-fill an HASKELL_OVERLAPPED structure.
zeroOverlapped :: LPHASKELL_OVERLAPPED -> IO ()
zeroOverlapped lpol = fillBytes lpol 0 #{size HASKELL_OVERLAPPED}
{-# INLINE zeroOverlapped #-}

-- | Set the offset field in an OVERLAPPED structure.
pokeOffsetOverlapped :: LPOVERLAPPED -> Word64 -> IO ()
pokeOffsetOverlapped lpol offset = do
  let (offsetHigh, offsetLow) = Win32.ddwordToDwords offset
  #{poke OVERLAPPED, Offset} lpol offsetLow
  #{poke OVERLAPPED, OffsetHigh} lpol offsetHigh
{-# INLINE pokeOffsetOverlapped #-}

------------------------------------------------------------------------
-- Cancel pending I/O

-- | CancelIo shouldn't block, but cancellation happens infrequently,
-- so we might as well be on the safe side.
foreign import WINDOWS_CCONV unsafe "windows.h CancelIoEx"
    c_CancelIoEx :: HANDLE -> LPOVERLAPPED -> IO BOOL

-- | Cancel all pending overlapped I/O for the given file that was initiated by
-- the current OS thread.  Cancelling is just a request for cancellation and
-- before the OVERLAPPED struct is freed we must make sure that the IRQ has been
-- removed from the queue.  See `getOverlappedResult`.
cancelIoEx :: HANDLE -> LPOVERLAPPED -> IO ()
cancelIoEx h o = failIfFalse_ "CancelIoEx" . c_CancelIoEx h $ o

cancelIoEx' :: HANDLE -> LPOVERLAPPED -> IO Bool
cancelIoEx' = c_CancelIoEx

------------------------------------------------------------------------
-- Monotonic time

foreign import WINDOWS_CCONV "windows.h GetTickCount64"
    c_GetTickCount64 :: IO #{type ULONGLONG}

-- | Call the @GetTickCount64@ function, which returns a monotonic time in
-- milliseconds.
--
-- Problems:
--
--  * Low resolution (10 to 16 milliseconds).
--
-- <http://msdn.microsoft.com/en-us/library/windows/desktop/ms724408%28v=vs.85%29.aspx>
getTickCount64 :: IO Word64
getTickCount64 = c_GetTickCount64

-- | Call the @QueryPerformanceCounter@ function.
--
-- Problems:
--
--  * Might not be available on some hardware.  Use 'queryPerformanceFrequency'
--    to test for availability before calling this function.
--
--  * On a multiprocessor computer, may produce different results on
--    different processors due to hardware bugs.
--
-- To get a monotonic time in seconds, divide the result of
-- 'queryPerformanceCounter' by that of 'queryPerformanceFrequency'.
--
-- <http://msdn.microsoft.com/en-us/library/windows/desktop/ms644904%28v=vs.85%29.aspx>
queryPerformanceCounter :: IO Int64
queryPerformanceCounter =
    callQP c_QueryPerformanceCounter
    >>= maybe (throwGetLastError "QueryPerformanceCounter") return

-- | Call the @QueryPerformanceFrequency@ function.  Return 'Nothing' if the
-- hardware does not provide a high-resolution performance counter.
--
-- <http://msdn.microsoft.com/en-us/library/windows/desktop/ms644905%28v=vs.85%29.aspx>
queryPerformanceFrequency :: IO (Maybe Int64)
queryPerformanceFrequency = do
    m <- callQP c_QueryPerformanceFrequency
    case m of
        Nothing   -> return Nothing
        Just 0    -> return Nothing -- Shouldn't happen; just a safeguard to
                                    -- avoid a zero denominator.
        Just freq -> return (Just freq)

type QPFunc = Ptr Int64 -> IO BOOL

foreign import WINDOWS_CCONV "Windows.h QueryPerformanceCounter"
    c_QueryPerformanceCounter :: QPFunc

foreign import WINDOWS_CCONV "Windows.h QueryPerformanceFrequency"
    c_QueryPerformanceFrequency :: QPFunc

callQP :: QPFunc -> IO (Maybe Int64)
callQP qpfunc =
    allocaBytes #{size LARGE_INTEGER} $ \ptr -> do
        ok <- qpfunc ptr
        if ok then do
            n <- #{peek LARGE_INTEGER, QuadPart} ptr
            return (Just n)
        else
            return Nothing

------------------------------------------------------------------------
-- Miscellaneous

type ULONG_PTR  = #type ULONG_PTR

throwWinErr :: String -> ErrCode -> IO a
throwWinErr loc err = do
    c_SetLastError err
    Win32.failWith loc err

setLastError :: ErrCode -> IO ()
setLastError = c_SetLastError

foreign import WINDOWS_CCONV unsafe "windows.h SetLastError"
    c_SetLastError :: ErrCode -> IO ()
