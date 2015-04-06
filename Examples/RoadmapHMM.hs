{-# LANGUAGE RankNTypes, TypeOperators, ScopedTypeVariables, TypeFamilies, FlexibleContexts #-}

module Examples.RoadmapHMM where

import Prelude hiding (Real)
import qualified Control.Monad

import qualified Data.Vector as V

import Language.Hakaru.Syntax
import Language.Hakaru.Sample
import Language.Hakaru.Expect
import Language.Hakaru.Embed
import Language.Hakaru.Disintegrate

-- To keep things concrete we will assume 5 latent states, 3 observed states
-- and a sequence of 20 transitions. We know we start in latent state 0.

type Table = Vector (Vector Prob)

symDirichlet :: (Lambda repr, Integrate repr, Mochastic repr) =>
                repr Int -> repr Prob -> repr (Measure (Vector Prob))
symDirichlet n a = liftM normalizeV (plate (constV n (gamma a 1)))

start :: Base repr => repr Int
start = 0

transMat :: (Lambda repr, Integrate repr, Mochastic repr) =>
            repr (Measure Table)
transMat = plate (vector 5 (\ i ->
                            symDirichlet 5 1))

emitMat :: (Lambda repr, Integrate repr, Mochastic repr) =>
            repr (Measure Table)
emitMat =  plate (vector 5 (\ i ->
                            symDirichlet 3 1))

transition :: (Lambda repr, Integrate repr, Mochastic repr) =>
              repr Table -> repr Int -> repr (Measure Int)
transition v s = categorical (index v s)

emission   :: (Lambda repr, Integrate repr, Mochastic repr) =>
              repr Table -> repr Int -> repr (Measure Int)
emission v s = categorical (index v s)

roadmapProg1 :: (Integrate repr, Lambda repr, Mochastic repr) =>
                repr (Measure (Vector Int, (Table, Table)))
roadmapProg1 = transMat `bind` \trans ->
               emitMat `bind`  \emit  ->
               app (chain (vector 20
                  (\ _ -> lam $ \s ->
                   transition trans s `bind` \s' ->
                   emission emit s' `bind` \o ->
                   dirac $ pair o s'
                  ))) start `bind` \x ->
               dirac (pair (fst_ x) (pair trans emit))

roadmapProg2 :: (Integrate repr, Lambda repr, Mochastic repr) =>
                repr (Vector Int) -> repr (Measure (Table, Table))
roadmapProg2 o = transMat `bind` \trans ->
                 emitMat `bind`  \emit  ->
                 app (chain (vector 20
                  (\ i -> lam $ \s ->
                   transition trans s `bind` \s' ->
                   factor (index (index emit s') (index o i)) `bind` \d ->
                   dirac $ pair d s'
                  ))) start `bind` \x ->
                 dirac (pair trans emit)

reflect :: (Mochastic repr, Lambda repr, Integrate repr) =>
           repr Table -> Expect repr (Int -> Measure Int)
reflect m = lam (\i -> let v = index (Expect m) i
                       in weight (summateV v) (categorical v))

reify :: (Mochastic repr, Lambda repr, Integrate repr) =>
         repr Int -> repr Int ->
         Expect repr (Int -> Measure Int) -> repr Table
reify domainSize rangeSize m =
  vector domainSize (\i ->
  vector rangeSize  (\j ->
  app (snd_ (app (unExpect m) i)) (lam (\j' -> if_ (equal j j') 1 0))))

bindo :: (Mochastic repr, Lambda repr) =>
         repr (a -> Measure b) ->
         repr (b -> Measure c) ->
         repr (a -> Measure c)
bindo f g = lam (\x -> app f x `bind` app g)

chain'' :: (Mochastic repr, Lambda repr, Integrate repr) =>
           repr (Vector Table) -> repr Table
chain'' = reduce bindo' (reify 5 5 (lam dirac))

bindo' :: (Mochastic repr, Lambda repr, Integrate repr) =>
          repr Table -> repr Table -> repr Table
bindo' m n = reify 5 5 (bindo (reflect m) (reflect n))

roadmapProg3 :: (Integrate repr, Lambda repr, Mochastic repr) =>
                Expect repr (Vector Int) -> Expect repr (Measure (Table, Table))
roadmapProg3 o = transMat `bind` \trans ->
                 emitMat `bind`  \emit  ->
                 app (reflect (chain'' (vector 20 $ \i ->
                                        reify 5 5 $
                                        lam $ \s ->
                                        transition trans s `bind` \s' ->
                                        factor (index
                                                (index emit s')
                                                (index o (Expect i))) `bind` \d ->
                                        dirac s')))
                 start `bind` \x ->
                 dirac (pair trans emit)

mcmc' :: (Lambda repr, Integrate repr, Mochastic repr, Order_ a) =>
     repr (Expect' a) -> repr (Expect' a) -> repr (Measure a) ->
     repr (Measure (Expect' a))
mcmc' old new target =
  let_ (density' target new / density' target old) $ \ratio ->
    bern (min_ 1 ratio) `bind` \accept ->
    dirac (if_ accept new old)

density' :: (Lambda repr, Integrate repr, Mochastic repr, Order_ a) =>
            repr (Measure a) -> repr (Expect' a) -> repr Prob
density' m a = undefined

-- Resample a row of both the emission and transmission matrices

roadmapProg4  :: (Integrate repr, Lambda repr, Mochastic repr) =>
                Expect repr (Vector Int) ->
                Expect repr (Table, Table) ->
                Expect repr (Measure (Table, Table))
roadmapProg4 o s  = unpair s (\ trans emit ->
                            symDirichlet (size trans) 1 `bind` \td ->
                            symDirichlet (size emit)  1 `bind` \ed ->
                            categorical td `bind` \ti ->
                            categorical ed `bind` \ei ->
                            let_ (index trans ti) (\trow ->
                            symDirichlet (size trow) 1 `bind` \trow' ->
                            let_ (vector (size trans) (\i ->
                                                 if_ (equal_ i ti)
                                                 trow'
                                                 (index trans i))) (\ trans' ->
                            let_ (index emit ei) (\erow ->
                            symDirichlet (size erow) 1 `bind` \erow' ->
                            let_ (vector (size emit) (\i ->
                                                 if_ (equal_ i ei)
                                                 erow'
                                                 (index emit i))) (\ emit' ->
                            mcmc' (pair trans emit) (pair trans' emit')
                                  (roadmapProg3 o))))))
