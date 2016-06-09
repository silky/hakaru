module HKC.Prelude where

{-
let_ :: a -> (a -> b) -> b
let_ x f = let x1 = x in f x1

normal :: Double -> Double -> MWC.GenIO -> IO Double
normal mu sd g = MWCD.normal mu sd g

(>>=) :: (MWC.GenIO -> IO a)
      -> (a -> MWC.GenIO -> IO b)
      -> MWC.GenIO
      -> IO b
m >>= f = \g -> m g M.>>= flip f g

dirac :: a -> MWC.GenIO -> IO a
dirac x _ = return x

nat_ :: Integer -> Integer
nat_ = id

nat2prob :: Integer -> Double
nat2prob = fromIntegral

nat2real :: Integer -> Double
nat2real = fromIntegral

real_ :: Rational -> Double
real_ = fromRational

prob_ :: NonNegativeRational -> Double
prob_ = fromRational . fromNonNegativeRational

run :: Show a => MWC.GenIO -> (MWC.GenIO -> IO a) -> IO ()
run g k = k g M.>>= print
-}
