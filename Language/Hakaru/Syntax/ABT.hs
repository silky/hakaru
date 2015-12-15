{-# LANGUAGE CPP
           , RankNTypes
           , ScopedTypeVariables
           , GADTs
           , StandaloneDeriving
           , DataKinds
           , PolyKinds
           , TypeOperators
           , MultiParamTypeClasses
           , FlexibleContexts
           , FlexibleInstances
           , FunctionalDependencies
           , UndecidableInstances
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2015.12.14
-- |
-- Module      :  Language.Hakaru.Syntax.ABT
-- Copyright   :  Copyright (c) 2015 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- The interface for abstract binding trees. Given the generating
-- functor 'Term': the non-recursive 'View' type extends 'Term' by
-- adding variables and binding; and each 'ABT' type (1) provides
-- some additional annotations at each recursion site, and then (2)
-- ties the knot to produce the recursive trees. For an introduction
-- to this technique\/approach, see:
--
--    * <http://semantic-domain.blogspot.co.uk/2015/03/abstract-binding-trees.html>
--    * <http://semantic-domain.blogspot.co.uk/2015/03/abstract-binding-trees-addendum.html>
--    * <http://winterkoninkje.dreamwidth.org/103978.html>
----------------------------------------------------------------
module Language.Hakaru.Syntax.ABT
    (
    -- * Our basic notion of variables.
      module Language.Hakaru.Syntax.Variable
    , resolveVar

    -- * The abstract binding tree interface
    -- See note about exposing 'View', 'viewABT', and 'unviewABT'
    , View(..)
    , unviewABT
    , ABT(..)
    , caseVarSyn
    , binds
    , binds_
    , caseBinds
    -- ** Capture avoiding substitution for any 'ABT'
    , subst
    , substs
    -- ** Constructing first-order trees with a HOAS-like API
    -- cf., <http://comonad.com/reader/2014/fast-circular-substitution/>
    , binder
    {-
    -- *** Highly experimental
    , Hint(..)
    , multibinder
    -}
    -- ** Some ABT instances
    , TrivialABT()
    , MemoizedABT()
    ) where

import           Data.Text         (Text)
import qualified Data.IntMap       as IM
import qualified Data.Foldable     as F
#if __GLASGOW_HASKELL__ < 710
import           Data.Monoid       (Monoid(..))
#endif

import Language.Hakaru.Syntax.Nat
import Language.Hakaru.Syntax.IClasses
import Language.Hakaru.Syntax.Sing
import Language.Hakaru.Syntax.Variable

----------------------------------------------------------------
----------------------------------------------------------------
-- TODO: (probably) parameterize the 'ABT' class over it's
-- implementation of 'Variable', so that after we're done constructing
-- terms with 'binder' we can make the varID strict\/unboxed.

-- TODO: (maybe) parameterize the 'ABT' class over it's implementation
-- of 'View' so that we can unpack the implementation of 'Variable'
-- into the 'Var' constructor. That is, the current version does
-- this unpacking, but if we parameterize the variable implementation
-- then we'd lose it; so this would allow us to regain it. Also,
-- if we do this, then 'MemoizedABT' could define it's own specialized
-- 'Bind' in order to keep track of whether bound variables occur
-- or not (for defining 'caseBind' precisely).


----------------------------------------------------------------
-- | The raw view of abstract binding trees, to separate out variables
-- and binders from (1) the rest of syntax (cf., 'Term'), and (2)
-- whatever annotations (cf., the 'ABT' instances).
--
-- The first parameter gives the generating signature for the
-- signature. The second index gives the number and types of
-- locally-bound variables. And the final parameter gives the type
-- of the whole expression.
--
-- HACK: We only want to expose the patterns generated by this type,
-- not the constructors themselves. That way, callers must use the
-- smart constructors of the ABT class. But if we don't expose this
-- type, then clients can't define their own ABT instances (without
-- reinventing their own copy of this type)...
data View :: (k -> *) -> [k] -> k -> * where
    -- BUG: haddock doesn't like annotations on GADT constructors
    -- <https://github.com/hakaru-dev/hakaru/issues/6>

    -- Some syntax from the generating signature @rec@.
    Syn  :: !(rec a) -> View rec '[] a

    -- A variable use.
    Var  :: {-# UNPACK #-} !(Variable a) -> View rec '[] a

    -- N.B., this constructor is recursive, thus minimizing the
    -- memory overhead of whatever annotations our ABT stores (we
    -- only annotate once, at the top of a chaing of 'Bind's, rather
    -- than before each one). However, in the 'ABT' class, we provide
    -- an API as if things went straight back to @abt@. Doing so
    -- requires that 'caseBind' is part of the class so that we
    -- can push whatever annotations down over one single level of
    -- 'Bind', rather than pushing over all of them at once and
    -- then needing to reconstruct all but the first one.
    --
    -- A variable binding.
    Bind
        :: {-# UNPACK #-} !(Variable a)
        -> !(View rec xs b)
        -> View rec (a ': xs) b


instance Functor12 View where
    fmap12 f (Syn  t)   = Syn  (f t)
    fmap12 _ (Var  x)   = Var  x
    fmap12 f (Bind x e) = Bind x (fmap12 f e)


instance (Show1 (Sing :: k -> *), Show1 rec)
    => Show2 (View (rec :: k -> *))
    where
    showsPrec2 p (Syn  t)   = showParen_1  p "Syn"  t
    showsPrec2 p (Var  x)   = showParen_1  p "Var"  x
    showsPrec2 p (Bind x v) = showParen_12 p "Bind" x v

instance (Show1 (Sing :: k -> *), Show1 rec)
    => Show1 (View (rec :: k -> *) xs)
    where
    showsPrec1 = showsPrec2
    show1      = show2

-- TODO: could weaken the Show1 requirements to Show requirements...
instance (Show1 (Sing :: k -> *), Show1 rec)
    => Show (View (rec :: k -> *) xs a)
    where
    showsPrec = showsPrec1
    show      = show1


-- TODO: neelk includes 'subst' as a method. Any reason we should?
-- TODO: jon includes instantiation as a method. Any reason we should?
-- TODO: require @(JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *), Foldable21 syn)@ since all our instances will need those too?
--
-- | The class interface for abstract binding trees. The first
-- argument, @syn@, gives the syntactic signature of the ABT;
-- whereas, the second argument, @abt@, is thing being declared as
-- an ABT for @syn@. The first three methods ('syn', 'var', 'bind')
-- alow us to inject any 'View' into the @abt@. The other methods
-- provide various views for extracting information from the @abt@.
--
-- At present we're using fundeps in order to restrict the relationship
-- between @abt@ and @syn@. However, in the future we may move @syn@
-- into being an associated type, if that helps to clean things up
-- (since fundeps and type families don't play well together). The
-- idea behind the fundep is that certain @abt@ implementations may
-- only be able to work for particular @syn@ signatures. This isn't
-- the case for 'TrivialABT' nor 'MemoizedABT', but isn't too
-- far-fetched.
class ABT (syn :: ([k] -> k -> *) -> k -> *) (abt :: [k] -> k -> *) | abt -> syn where
    -- Smart constructors for building a 'View' and then injecting it into the @abt@.
    syn  :: syn abt  a -> abt '[] a
    var  :: Variable a -> abt '[] a
    bind :: Variable a -> abt xs b -> abt (a ': xs) b

    -- TODO: better name. "unbind"? "fromBind"?
    --
    -- When the left side is defined, we have the following laws:
    -- > caseBind e bind == e
    -- > caseBind (bind x e) k == k x (unviewABT $ viewABT e)
    -- However, we do not necessarily have the following:
    -- > caseBind (bind x e) k == k x e
    -- because the definition of 'caseBind' for 'MemoizedABT'
    -- is not exact.
    --
    -- | Since the first argument to @abt@ is not @'[]@, we know
    -- it must be 'Bind'. So we do case analysis on that constructor,
    -- pushing the annotation down one binder (but not over the
    -- whole recursive 'View' layer).
    caseBind :: abt (x ': xs) a -> (Variable x -> abt xs a -> r) -> r

    -- See note about exposing 'View', 'viewABT', and 'unviewABT'.
    -- We could replace 'viewABT' with a case-elimination version...
    viewABT  :: abt xs a -> View (syn abt) xs a

    freeVars :: abt xs a -> VarSet (KindOf a)

    -- | Return the successor of the largest 'varID' of /free/
    -- variables. Thus, if there are no free variables we return
    -- zero. The default implementation is to take the successor
    -- of the maximum of 'freeVars'. This is part of the class in
    -- case you want to memoize it.
    --
    -- This function is used in order to generate guaranteed-fresh
    -- variables without the need for a name supply. In particular,
    -- it's used to ensure that the generated variable don't capture
    -- any free variables in the term.
    nextFree :: abt xs a -> Nat
    nextFree = nextVarID . freeVars

    -- | Return the successor of the largest 'varID' of variable
    -- /binding sites/ (i.e., of variables bound by the 'Bind'
    -- constructor). Thus, if there are no binders, then we will
    -- return zero. N.B., this should return zero for /uses/ of the
    -- bound variables themselves. This is part of the class in
    -- case you want to memoize it.
    --
    -- This function is used in order to generate guaranteed-fresh
    -- variables without the need for a name supply. In particular,
    -- it's used to ensure that the generated variable won't be
    -- captured or shadowed by bindings already in the term.
    nextBind :: abt xs a -> Nat


    -- TODO: add a function for checking alpha-equivalence? Refreshing all variable IDs to be in some canonical form? Other stuff?


-- See note about exposing 'View', 'viewABT', and 'unviewABT'
unviewABT :: (ABT syn abt) => View (syn abt) xs a -> abt xs a
unviewABT (Syn  t)   = syn  t
unviewABT (Var  x)   = var  x
unviewABT (Bind x v) = bind x (unviewABT v)


-- | Since the first argument to @abt@ is @'[]@, we know it must
-- be either 'Syn' of 'Var'. So we do case analysis with those two
-- constructors.
caseVarSyn
    :: (ABT syn abt)
    => abt '[] a
    -> (Variable a -> r)
    -> (syn abt  a -> r)
    -> r
caseVarSyn e var_ syn_ =
    case viewABT e of
    Syn t -> syn_ t
    Var x -> var_ x


-- | Call 'bind' repeatedly.
binds :: (ABT syn abt) => List1 Variable xs -> abt ys b -> abt (xs ++ ys) b
binds Nil1         e = e
binds (Cons1 x xs) e = bind x (binds xs e)

-- | A specialization of 'binds' for when @ys ~ '[]@. We define
-- this to avoid the need for using 'eqAppendIdentity' on the result
-- of 'binds' itself.
binds_ :: (ABT syn abt) => List1 Variable xs -> abt '[] b -> abt xs b
binds_ Nil1         e = e
binds_ (Cons1 x xs) e = bind x (binds_ xs e)


-- TODO: take a continuation so that the type more closely resembles 'caseBind'; or, remove the CPSing in 'caseBind' so it more closely resembles this
-- | Call 'caseBind' repeatedly. (Actually we use 'viewABT'.)
caseBinds :: (ABT syn abt) => abt xs a -> (List1 Variable xs, abt '[] a)
caseBinds = go . viewABT
    where
    go  :: (ABT syn abt)
        => View (syn abt) xs a -> (List1 Variable xs, abt '[] a)
    go (Syn  t)   = (Nil1, syn t)
    go (Var  x)   = (Nil1, var x)
    go (Bind x v) = let ~(xs,e) = go v in (Cons1 x xs, e)

----------------------------------------------------------------
----------------------------------------------------------------
-- | A trivial ABT with no annotations.
--
-- The 'Show' instance does not expose the raw underlying data
-- types, but rather prints the smart constructors 'var', 'syn',
-- and 'bind'. This makes things prettier, but also means that if
-- you paste the string into a Haskell file you can use it for any
-- 'ABT' instance.
--
-- The 'freeVars', 'nextFree', and 'nextBind' methods are all very
-- expensive for this ABT, because we have to traverse the term
-- every time we want to call them. The 'MemoizedABT' implementation
-- fixes this.
--
-- N.B., The 'nextBind' method is not as expensive as it could be.
-- As a performance hack, we do not traverse under binders. If every
-- binding form is generated by using 'binder', then this is in
-- fact sound because all nested binders will bind smaller variables.
-- However, If you generate any binding forms manually, then you
-- can break things so that 'nextBind' returns an incorrect answer.
newtype TrivialABT (syn :: ([k] -> k -> *) -> k -> *) (xs :: [k]) (a :: k) =
    TrivialABT (View (syn (TrivialABT syn)) xs a)

instance (JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *), Foldable21 syn)
    => ABT (syn :: ([k] -> k -> *) -> k -> *) (TrivialABT syn)
    where
    syn  t                = TrivialABT (Syn  t)
    var  x                = TrivialABT (Var  x)
    bind x (TrivialABT v) = TrivialABT (Bind x v)

    caseBind (TrivialABT v) k =
        case v of
        Bind x v' -> k x (TrivialABT v')

    viewABT (TrivialABT v) = v

    freeVars = go . viewABT
        where
        go  :: View (syn (TrivialABT syn)) xs a
            -> VarSet (KindOf a)
        go (Syn  t)   = foldMap21 freeVars t
        go (Var  x)   = singletonVarSet x
        go (Bind x v) = deleteVarSet x (go v)

    nextBind = go 0 . viewABT
        where
        -- For multibinders (i.e., nested uses of Bind) we recurse
        -- through the whole binder, just to be sure. However, we should
        -- be able to just look at the first binder, since whenever we
        -- figure out how to do multibinders we can prolly arrange for
        -- the first one to be the largest.
        go :: Nat -> View (syn (TrivialABT syn)) xs a -> Nat
        go 0 (Syn  t)   = unMaxNat $ foldMap21 (MaxNat . nextBind) t
        go n (Syn  _)   = n -- Don't go under binders
        go n (Var  _)   = n -- Don't look at variable *uses*
        go n (Bind x v) = go (n `max` (1 + varID x)) v


-- BUG: requires UndecidableInstances
instance (Show1 (Sing :: k -> *), Show1 (syn (TrivialABT syn)))
    => Show2 (TrivialABT (syn :: ([k] -> k -> *) -> k -> *))
    where
    {-
    -- Print the concrete data constructors:
    showsPrec2 p (TrivialABT v) =
        showParen (p > 9)
            ( showString "TrivialABT "
            . showsPrec1 11 v
            )
    -}
    -- Do something a bit prettier. (Because we print the smart
    -- constructors, this output can also be cut-and-pasted to work
    -- for any ABT instance.)
    showsPrec2 p (TrivialABT (Syn  t))   = showParen_1  p "syn"  t
    showsPrec2 p (TrivialABT (Var  x))   = showParen_1  p "var"  x
    showsPrec2 p (TrivialABT (Bind x v)) = showParen_11 p "bind" x (TrivialABT v)

instance (Show1 (Sing :: k -> *), Show1 (syn (TrivialABT syn)))
    => Show1 (TrivialABT (syn :: ([k] -> k -> *) -> k -> *) xs)
    where
    showsPrec1 = showsPrec2
    show1      = show2

-- TODO: could weaken the Show1 requirements to Show requirements...
instance (Show1 (Sing :: k -> *), Show1 (syn (TrivialABT syn)))
    => Show (TrivialABT (syn :: ([k] -> k -> *) -> k -> *) xs a)
    where
    showsPrec = showsPrec1
    show      = show1

----------------------------------------------------------------
-- TODO: replace @VarSet@ with @VarMap Nat@ where the
-- Nat is the number of times the variable occurs. That way, we can
-- tell when a bound variable is unused or only used only once (and
-- hence performing beta\/let reduction would be a guaranteed win),
-- and if it's used more than once then we can use the number of
-- occurances in our heuristic for deciding whether reduction would
-- be a win or not.
--
-- TODO: generalize this pattern for any monoidal annotation?
-- TODO: what is the performance cost of letting 'memoizedFreeVars' be lazy? Is it okay to lose the ability to use 'binder' in order to shore that up?


-- WARNING: in older versions of the library, there was an issue
-- about the memoization of 'nextBind' breaking our ability to
-- tie-the-knot in 'binder'. Everything seems to work now, but it's
-- not entirely clear to me what changed...

-- | An ABT which memoizes 'freeVars', 'nextBind', and 'nextFree',
-- thereby making them take only /O(1)/ time.
--
-- N.B., the memoized set of free variables is lazy so that we can
-- tie-the-knot in 'binder' without interfering with our memos. The
-- memoized 'nextFree' must be lazy for the same reason.
data MemoizedABT (syn :: ([k] -> k -> *) -> k -> *) (xs :: [k]) (a :: k) =
    MemoizedABT
        { _memoizedFreeVars :: VarSet (KindOf a) -- N.B., lazy!
        , memoizedNextFree  :: Nat -- N.B., lazy!
        , memoizedNextBind  :: {-# UNPACK #-} !Nat
        , memoizedView      :: !(View (syn (MemoizedABT syn)) xs a)
        }

-- HACK: ""Cannot use record selector ‘_memoizedFreeVars’ as a function due to escaped type variables""
memoizedFreeVars :: MemoizedABT syn xs a -> VarSet (KindOf a)
memoizedFreeVars (MemoizedABT xs _ _ _) = xs


instance (JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *), Foldable21 syn)
    => ABT (syn :: ([k] -> k -> *) -> k -> *) (MemoizedABT syn)
    where
    syn t =
        MemoizedABT
            (foldMap21 freeVars t)
            (unMaxNat $ foldMap21 (MaxNat . nextFree) t)
            (unMaxNat $ foldMap21 (MaxNat . nextBind) t)
            (Syn t)

    var x =
        MemoizedABT
            (singletonVarSet x)
            (varID x)
            0
            (Var x)

    bind x (MemoizedABT xs _ mb v) =
        let xs' = deleteVarSet x xs
        in MemoizedABT
            xs'
            (nextVarID xs')
            (varID x `max` mb)
            (Bind x v)

    -- N.B., when we go under the binder, the variable @x@ may not
    -- actually be used, but we add it to the set of freeVars
    -- anyways. The reasoning is thus: this function is mainly used
    -- in defining 'subst', and for that purpose it's important to
    -- track all the variables which /could be/ free, so that we
    -- can freshen appropriately. It may be safe to not include @x@
    -- when @x@ is not actually used in @v'@, but it's best not to
    -- risk it. Moreover, once we add support for open terms (i.e.,
    -- truly-free variables) then we'll need to account for the
    -- fact that the variable @x@ may come to be used in the grounding
    -- of the open term, even though it's not used in the part of
    -- the term we already know. Similarly, the true 'nextBind' may
    -- be lower now that we're going under this binding; but keeping
    -- it the same is an always valid approximation.
    --
    -- TODO: we could actually compute things exactly, similar to
    -- how we do it in 'syn'; but unclear if that's really worth it...
    caseBind (MemoizedABT xs mf mb v) k =
        case v of
        Bind x v' ->
            k x $ MemoizedABT
                (insertVarSet x xs)
                (varID x `max` mf)
                mb
                v'

    viewABT  = memoizedView
    freeVars = memoizedFreeVars
    nextFree = memoizedNextFree
    nextBind = memoizedNextBind


instance (Show1 (Sing :: k -> *), Show1 (syn (MemoizedABT syn)))
    => Show2 (MemoizedABT (syn :: ([k] -> k -> *) -> k -> *))
    where
    showsPrec2 p (MemoizedABT xs mf mb v) =
        showParen (p > 9)
            ( showString "MemoizedABT "
            . showsPrec  11 xs
            . showString " "
            . showsPrec  11 mf
            . showString " "
            . showsPrec  11 mb
            . showString " "
            . showsPrec1 11 v
            )

instance (Show1 (Sing :: k -> *), Show1 (syn (MemoizedABT syn)))
    => Show1 (MemoizedABT (syn :: ([k] -> k -> *) -> k -> *) xs)
    where
    showsPrec1 = showsPrec2
    show1      = show2

-- TODO: could weaken the Show1 requirements to Show requirements...
instance (Show1 (Sing :: k -> *), Show1 (syn (MemoizedABT syn)))
    => Show (MemoizedABT (syn :: ([k] -> k -> *) -> k -> *) xs a)
    where
    showsPrec = showsPrec1
    show      = show1


----------------------------------------------------------------
----------------------------------------------------------------
-- TODO: should we export 'freshen' and 'rename'?

-- TODO: do something smarter
-- | If the variable is in the set, then construct a new one which
-- isn't (but keeping the same hint and type as the old variable).
-- If it isn't in the set, then just return it.
freshen
    :: (JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *))
    => Variable (a :: k)
    -> VarSet (KindOf a)
    -> Variable a
freshen x xs
    | x `memberVarSet` xs = let i = nextVarID xs in i `seq` x{varID = i}
    | otherwise           = x


-- | Rename a free variable. Does nothing if the variable is bound.
rename
    :: forall syn abt (a :: k) xs (b :: k)
    .  (JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *), Functor21 syn, ABT syn abt)
    => Variable a
    -> Variable a
    -> abt xs b
    -> abt xs b
rename x y = start
    where
    start :: forall xs' b'. abt xs' b' -> abt xs' b'
    start e = loop e (viewABT e)

    -- TODO: is it actually worth passing around the @e@? Benchmark.
    loop :: forall xs' b'. abt xs' b' -> View (syn abt) xs' b' -> abt xs' b'
    loop _ (Syn t) = syn $! fmap21 start t
    loop e (Var z) =
        case varEq x z of
        Just Refl -> var y
        Nothing   -> e
    loop e (Bind z v) =
        case varEq x z of
        Just Refl -> e
        Nothing   -> bind z $ loop (caseBind e $ const id) v


-- TODO: keep track of a variable renaming environment, and do renaming on the fly rather than traversing the ABT repeatedly.
--
-- TODO: make an explicit distinction between substitution in general vs instantiation of the top-level bound variable (i.e., the function of type @abt (x ': xs) a -> abt '[] x -> abt xs a@). cf., <http://hackage.haskell.org/package/abt>
--
-- | Perform capture-avoiding substitution. This function will
-- either preserve type-safety or else throw an 'VarEqTypeError'
-- (depending on which interpretation of 'varEq' is chosen). N.B.,
-- to ensure timely throwing of exceptions, the 'Term' and 'ABT'
-- should have strict 'fmap21' definitions.
subst
    :: forall syn abt (a :: k) xs (b :: k)
    .  (JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *), Functor21 syn, ABT syn abt)
    => Variable a
    -> abt '[]  a
    -> abt xs   b
    -> abt xs   b
subst x e = start
    where
    start :: forall xs' b'. abt xs' b' -> abt xs' b'
    start f = loop f (viewABT f)

    -- TODO: is it actually worth passing around the @f@? Benchmark.
    loop :: forall xs' b'. abt xs' b' -> View (syn abt) xs' b' -> abt xs' b'
    loop _ (Syn t) = syn $! fmap21 start t
    loop f (Var z) =
        case varEq x z of
        Just Refl -> e
        Nothing   -> f
    loop f (Bind z _) =
        case varEq x z of
        Just Refl -> f
        Nothing   ->
            -- TODO: even if we don't come up with a smarter way
            -- of freshening variables, it'd be better to just pass
            -- both sets to 'freshen' directly and then check them
            -- each; rather than paying for taking their union every
            -- time we go under a binder like this.
            let z' = freshen z (freeVars e `mappend` freeVars f) in
            -- HACK: the 'rename' function requires an ABT not a
            -- View, so we have to use 'caseBind' to give its
            -- input and then 'viewABT' to discard the topmost
            -- annotation. We really should find a way to eliminate
            -- that overhead.
            caseBind f $ \_ f' ->
                bind z' . loop f' . viewABT $ rename z z' f'


-- BUG: This appears to have both capture and escape issues as demonstrated by 'Tests.Disintegrate.test0' and commented on at 'Language.Hakaru.Evaluation.Types.runM'.
-- | The parallel version of 'subst' for performing multiple substitutions at once.
substs
    :: forall
        (syn :: ([k] -> k -> *) -> k -> *)
        (abt :: [k] -> k -> *)
        (xs  :: [k])
        (a   :: k)
    .   ( ABT syn abt
        , JmEq1 (Sing :: k -> *)
        , Show1 (Sing :: k -> *)
        , Functor21 syn
        )
    => Assocs abt
    -> abt xs a
    -> abt xs a
substs rho0 =
    -- Guaranteed correct (since 'subst' is correct) but very inefficient
    \e0 -> F.foldl (\e (Assoc x v) -> subst x v e) e0 (unAssocs rho0)
    {- -- old buggy version
    start rho0
    where
    fv0 :: VarSet (KindOf a)
    fv0 = F.foldMap (\(Assoc _ e) -> freeVars e) (unAssocs rho0)

    start :: forall xs' a'. Assocs abt -> abt xs' a' -> abt xs' a'
    start rho e = loop rho e (viewABT e)

    loop :: forall xs' a'
        . Assocs abt -> abt xs' a' -> View (syn abt) xs' a' -> abt xs' a'
    loop rho _ (Syn t) = syn $! fmap21 (start rho) t
    loop rho e (Var x) =
        case IM.lookup (fromNat $ varID x) (unAssocs rho) of
        Nothing           -> e
        Just (Assoc y e') ->
            case varEq x y of
            Just Refl     -> e'
            Nothing       -> e
    loop rho e (Bind x _body) =
        case IM.lookup (fromNat $ varID x) (unAssocs rho) of
        Nothing          -> e
        Just (Assoc y _) ->
            case varEq x y of
            Just Refl ->
                let rho' = IM.delete (fromNat $ varID x) (unAssocs rho) in
                if IM.null rho'
                then e
                else caseBind e $ \_x body' ->
                        bind x . loop (Assocs rho') body' $ viewABT body'
            Nothing   ->
                -- TODO: even if we don't come up with a smarter way
                -- of freshening variables, it'd be better to just pass
                -- both sets to 'freshen' directly and then check them
                -- each; rather than paying for taking their union every
                -- time we go under a binder like this.
                let x' = freshen x (fv0 `mappend` freeVars e) in
                -- HACK: the 'rename' function requires an ABT not a
                -- View, so we have to use 'caseBind' to give its
                -- input and then 'viewABT' to discard the topmost
                -- annotation. We really should find a way to eliminate
                -- that overhead.
                caseBind e $ \_x body' ->
                    bind x' . loop rho body' . viewABT $ rename x x' body'
    -}


----------------------------------------------------------------
----------------------------------------------------------------
-- | A combinator for defining a HOAS-like API for our syntax.
-- Because our 'Term' is first-order, we cannot actually have any
-- exotic terms in our language. In principle, this function could
-- be used to do exotic things when constructing those non-exotic
-- terms; however, trying to do anything other than change the
-- variable's name hint will cause things to explode (since it'll
-- interfere with our tying-the-knot).
--
-- N.B., if you manually construct free variables and use them in
-- the body (i.e., via 'var'), they may become captured by the new
-- binding introduced here! This is inevitable since 'nextBind'
-- never looks at variable /use sites/; it only ever looks at
-- /binding sites/. On the other hand, if you manually construct a
-- bound variable (i.e., manually calling 'bind' yourself), then
-- the new binding introduced here will respect the old binding and
-- avoid that variable ID.
binder
    :: (ABT syn abt)
    => Text                     -- ^ The variable's name hint
    -> Sing a                   -- ^ The variable's type
    -> (abt '[] a -> abt xs b)  -- ^ Build the binder's body from a variable
    -> abt (a ': xs) b
binder hint typ hoas = bind x body
    where
    body = hoas (var x)
    x    = Variable hint (nextBind body) typ
    -- N.B., cannot use 'nextFree' when deciding the 'varID' of @x@

{-
data Hint (a :: k)
    = Hint !Text !(Sing a)

instance Show1 Hint where
    showsPrec1 p (Hint x s) = showParen_01 p "Hint" x s

instance Show (Hint a) where
    showsPrec = showsPrec1
    show      = show1

data VS (a :: k)
    = VS {-# UNPACK #-} !Variable !(Sing a)

-- this typechecks, and it works!
-- BUG: but it seems fairly unusable. We must give explicit type signatures to any lambdas passed as the second argument, otherwise it complains about not knowing enough about the types in @xs@... Also, the uncurriedness of it isn't very HOAS-like
multibinder
    :: (ABT abt) => List1 Hint xs -> (List1 abt xs -> abt b) -> abt b
multibinder names hoas = binds vars body
    where
    vars = go 0 names
        where
        -- BUG: this puts the largest binder on the inside
        go :: Nat -> List1 Hint xs -> List1 VS xs
        go _ Nil                         = Nil
        go n (Cons (Hint name typ) rest) =
            Cons (VS (Variable name (maxBind body + n) typ) typ)
                ((go $! n + 1) rest)
    body = hoas (go vars)
        where
        go :: ABT abt => List1 VS xs -> List1 abt xs
        go Nil                    = Nil
        go (Cons (VS x typ) rest) = Cons (var x typ) (go rest)

    binds :: ABT abt => List1 VS xs -> abt a -> abt a
    binds Nil                  = id
    binds (Cons (VS x _) rest) = bind x . binds rest
-}

----------------------------------------------------------------
----------------------------------------------------------------

-- TODO: Swap the argument order?
-- | If the expression is a variable, then look it up. Recursing
-- until we can finally return some syntax.
resolveVar
    :: (JmEq1 (Sing :: k -> *), Show1 (Sing :: k -> *), ABT syn abt)
    => abt '[] (a :: k)
    -> Assocs abt
    -> Either (Variable a) (syn abt a)
resolveVar e xs =
    flip (caseVarSyn e) Right $ \x ->
        case lookupAssoc x xs of
        Just e' -> resolveVar e' xs
        Nothing -> Left x

----------------------------------------------------------------
----------------------------------------------------------- fin.
