{-# LANGUAGE CPP, PatternGuards #-}
module Agda.TypeChecking.With where

import Control.Applicative
import Control.Monad
import Control.Monad.State
import qualified Data.Traversable as T (mapM, traverse)
import Data.List

import Agda.Syntax.Common
import Agda.Syntax.Internal as I
import Agda.Syntax.Abstract (LHS(..), RHS(..))
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Info
import Agda.Syntax.Position

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Primitive hiding (Nat)
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Rules.LHS.Implicit
import Agda.TypeChecking.Rules.LHS.Split (expandLitPattern)
import Agda.TypeChecking.Abstract
import Agda.TypeChecking.EtaContract
import Agda.TypeChecking.Telescope

import Agda.Utils.List
import Agda.Utils.Permutation
import Agda.Utils.Size

#include "../undefined.h"
import Agda.Utils.Impossible

-- showPat moved to TypeChecking.Pretty as prettyTCM instance

withFunctionType :: Telescope -> [Term] -> [Type] -> Telescope -> Type -> TCM Type
withFunctionType delta1 vs as delta2 b = {-dontEtaContractImplicit $-} do
  (vas, b) <- addCtxTel delta1 $ do
    vs <- etaContract =<< normalise vs
    as <- etaContract =<< normalise as
    b  <- etaContract =<< normalise (telePi_ delta2 b)
    reportSDoc "tc.with.abstract" 40 $
      sep [ text "abstracting"
          , nest 2 $ vcat $
            [ text "vs = " <+> prettyTCM vs
            , text "as = " <+> prettyTCM as
            , text "b  = " <+> prettyTCM b ]
          ]
    reportSLn "tc.with.abstract" 50 $ "  raw vs = " ++ show vs ++ "\n  raw b  = " ++ show b
    return (zip vs as, b)
  return $ telePi_ delta1 $ foldr (uncurry piAbstractTerm) b vas

-- | Compute the clauses for the with-function given the original patterns.
buildWithFunction :: QName -> Telescope -> [I.Arg Pattern] -> Permutation ->
                     Nat -> Nat -> [A.Clause] -> TCM [A.Clause]
buildWithFunction aux gamma qs perm n1 n cs = mapM buildWithClause cs
  where
    buildWithClause (A.Clause (LHS i (A.LHSProj{}) wps) rhs wh) =
      typeError $ NotImplemented "with clauses for definitions by copatterns"
    buildWithClause (A.Clause (LHS i (A.LHSHead _ ps) wps) rhs wh) = do
      let (wps0, wps1) = genericSplitAt n wps
          ps0          = map defaultNamedArg wps0
      rhs <- buildRHS rhs
      (ps1, ps2)  <- genericSplitAt n1 <$> stripWithClausePatterns gamma qs perm ps
      let result = A.Clause (LHS i (A.LHSHead aux (ps1 ++ ps0 ++ ps2)) wps1) rhs wh
      reportSDoc "tc.with" 20 $ vcat
        [ text "buildWithClause returns" <+> prettyA result
        ]
      return result

    buildRHS rhs@(RHS _)               = return rhs
    buildRHS rhs@AbsurdRHS             = return rhs
    buildRHS (WithRHS q es cs)         = WithRHS q es <$> mapM buildWithClause cs
    buildRHS (RewriteRHS q eqs rhs wh) = flip (RewriteRHS q eqs) wh <$> buildRHS rhs

{-| @stripWithClausePatterns Γ qs π ps = ps'@

    @Δ@ - context bound by lhs of original function (not an argument)

    @Γ@ - type of arguments to original function

    @qs@ - internal patterns for original function

    @π@ - permutation taking @vars(qs)@ to @support(Δ)@

    @ps@ - patterns in with clause (presumably of type @Γ@)

    @ps'@ - patterns for with function (presumably of type @Δ@)
-}
stripWithClausePatterns :: Telescope -> [I.Arg Pattern] -> Permutation -> [A.NamedArg A.Pattern] -> TCM [A.NamedArg A.Pattern]
stripWithClausePatterns gamma qs perm ps = do
  psi <- insertImplicitPatterns ExpandLast ps gamma
  unless (size psi == size gamma) $
    typeError $ GenericError $ "Wrong number of arguments in with clause: given " ++ show (size psi) ++ ", expected " ++ show (size gamma)
  reportSDoc "tc.with.strip" 10 $ vcat
    [ text "stripping patterns"
    , nest 2 $ text "gamma = " <+> prettyTCM gamma
    , nest 2 $ text "psi = " <+> fsep (punctuate comma $ map prettyA psi)
    , nest 2 $ text "qs  = " <+> fsep (punctuate comma $ map (prettyTCM . unArg) qs)
    ]
  ps' <- strip gamma psi qs
  let psp = permute perm ps'
  reportSDoc "tc.with.strip" 10 $ vcat
    [ nest 2 $ text "ps' = " <+> fsep (punctuate comma $ map prettyA ps')
    , nest 2 $ text "psp = " <+> fsep (punctuate comma $ map prettyA $ psp)
    ]
  return psp
  where
    -- implicit args inserted at top level
    -- all three arguments should have the same size
    strip :: Telescope -> [A.NamedArg A.Pattern] -> [I.Arg Pattern] -> TCM [A.NamedArg A.Pattern]
    strip _           []      (_ : _) = __IMPOSSIBLE__
    strip _           (_ : _) []      = __IMPOSSIBLE__
    strip EmptyTel    (_ : _) _       = __IMPOSSIBLE__
    strip ExtendTel{} []      _       = __IMPOSSIBLE__
    strip EmptyTel    []      []      | 0 == 0 = return []
    strip tel0@(ExtendTel a tel) ps0@(p0 : ps) qs0@(q : qs) = do
      p <- expandLitPattern p0
      reportSDoc "tc.with.strip" 15 $ vcat
        [ text "strip"
        , nest 2 $ text "ps0 =" <+> fsep (punctuate comma $ map prettyA ps0)
        , nest 2 $ text "exp =" <+> prettyA p
        , nest 2 $ text "qs0 =" <+> fsep (punctuate comma $ map (prettyTCM . unArg) qs0)
        , nest 2 $ text "tel0=" <+> prettyTCM tel0
        ]
      case unArg q of
        VarP _  -> do
          ps <- underAbstraction a tel $ \tel -> strip tel ps qs
          return $ p : ps

        DotP v  -> case namedArg p of
          A.DotP _ _    -> ok p
          A.ImplicitP _ -> ok p
          -- Andreas, 2013-03-21 in case the implicit A.pattern has already been eta-expanded
          -- we just fold it back.  This fixes issues 665 and 824.
          A.ConP ci _ _ | patImplicit ci -> ok $ updateNamedArg (const $ A.ImplicitP patNoRange) p
          _ -> do
            d <- prettyA p
            typeError $ GenericError $
                "Inaccessible (dotted) patterns from the parent clause must " ++
                "also be inaccessible in the with clause, when checking the " ++
                "pattern " ++ show d ++ ","
          where
            ok p = do
              ps <- strip (tel `absApp` v) ps qs
              return $ p : ps

        ConP c ci qs' -> case namedArg p of
          -- Andreas, 2013-03-21 if we encounter an implicit pattern in the with-clause
          -- that has been expanded in the parent clause, we expand it and restart
          A.ImplicitP _ | Just (True, _) <- ci -> do
            maybe __IMPOSSIBLE__ (\ p -> strip tel0 (p : ps) qs0) =<<
              expandImplicitPattern' (unDom a) p


          A.ConP _ (A.AmbQ cs') ps' -> do

            Con c' [] <- ignoreSharing <$> (constructorForm =<< reduce (Con c []))
            c <- return $ c' `withRangeOf` c
            let getCon (Con c []) = c
                getCon (Shared p) = getCon (derefPtr p)
                getCon _ = __IMPOSSIBLE__
            cs' <- map getCon <$> (mapM constructorForm =<< mapM (\c' -> reduce $ Con c' []) cs')

            unless (elem c cs') mismatch

            -- The type is a datatype
            Def d us <- ignoreSharing <$> normalise (unEl $ unDom a)

            -- Compute the argument telescope for the constructor
            Con c []    <- ignoreSharing <$> (constructorForm =<< normalise (Con c []))
            Defn {defType = ct, theDef = Constructor{conPars = np}}  <- getConstInfo c
            let ct' = ct `apply` genericTake np us
            TelV tel' _ <- telView ct'

            reportSDoc "tc.with.strip" 20 $
              vcat [ text "ct  = " <+> prettyTCM ct
                   , text "ct' = " <+> prettyTCM ct'
                   , text "np  = " <+> text (show np)
                   , text "us  = " <+> prettyList (map prettyTCM us)
                   , text "us' = " <+> prettyList (map prettyTCM $ genericTake np us)
                   ]

            -- Compute the new telescope
            let v     = Con c [ Arg info (var i) | (i, Arg info _) <- zip (downFrom $ size qs') qs' ]
--            let v     = Con c $ reverse [ Arg h r (var i) | (i, Arg h r _) <- zip [0..] $ reverse qs' ]
                tel'' = tel' `abstract` absApp (raise (size tel') tel) v

            reportSDoc "tc.with.strip" 15 $ sep
              [ text "inserting implicit"
              , nest 2 $ prettyList $ map prettyA (ps' ++ ps)
              , nest 2 $ text ":" <+> prettyTCM tel''
              ]

            -- Insert implicit patterns (just for the constructor arguments)
            psi' <- insertImplicitPatterns ExpandLast ps' tel'
            unless (size psi' == size tel') $ typeError $ WrongNumberOfConstructorArguments c (size tel') (size psi')

            -- Do it again for everything (is this necessary?)
            psi' <- insertImplicitPatterns ExpandLast (psi' ++ ps) tel''

            -- Keep going
            strip tel'' psi' (qs' ++ qs)
          _ -> mismatch

        LitP lit -> case namedArg p of
          A.LitP lit' | lit == lit' -> strip (tel `absApp` Lit lit) ps qs
          _ -> mismatch
      where
        mismatch = typeError $ WithClausePatternMismatch (namedArg p0) (unArg q)
    strip tel ps qs = error $ "huh? " ++ show (size tel) ++ " " ++ show (size ps) ++ " " ++ show (size qs)

-- | Construct the display form for a with function. It will display
--   applications of the with function as applications to the original function.
--   For instance, @aux a b c@ as @f (suc a) (suc b) | c@
--
--   @n@ is the number of with arguments.
withDisplayForm :: QName -> QName -> Telescope -> Telescope -> Nat -> [I.Arg Pattern] -> Permutation -> Permutation -> TCM DisplayForm
withDisplayForm f aux delta1 delta2 n qs perm@(Perm m _) lhsPerm = do
  topArgs <- raise (n + size delta1 + size delta2) <$> getContextArgs
  x <- freshNoName_
  let wild = Def (qualify (mnameFromList []) x) []

  let tqs = patsToTerms lhsPerm qs
      top = genericLength topArgs
      vs = map (fmap DTerm) topArgs ++ applySubst (sub ys wild) tqs
      dt = DWithApp (DDef f vs : map DTerm withArgs) []
      withArgs = map var $ genericTake n $ downFrom $ size delta2 + n
--      withArgs = reverse $ map var [size delta2..size delta2 + n - 1]
      pats = genericReplicate (n + size delta1 + size delta2 + top) (var 0)
      -- Building the arguments to the with function
      (ys0, ys1) = splitAt (size delta1) (permute perm $ map Just [m - 1, m - 2..0])
      ys = reverse $ ys0 ++ genericReplicate n Nothing ++ ys1

  let display = Display (n + size delta1 + size delta2 + top) pats dt
      addFullCtx = addCtxTel delta1
                 . flip (foldr addCtxString_) (map ("w" ++) $ map show [1..n])
                 . addCtxTel delta2
          -- Andreas 2012-09-17: this seems to be the right order of contexts

  reportSDoc "tc.with.display" 20 $ vcat
    [ text "withDisplayForm"
    , nest 2 $ vcat
      [ text "f      =" <+> text (show f)
      , text "aux    =" <+> text (show aux)
      , text "delta1 =" <+> prettyTCM delta1
      , text "delta2 =" <+> do addCtxTel delta1 $ prettyTCM delta2
      , text "n      =" <+> text (show n)
      , text "perm   =" <+> text (show perm)
      , text "top    =" <+> do addFullCtx $ prettyTCM topArgs
      , text "qs     =" <+> text (show qs)
      , text "dt     =" <+> do addFullCtx $ prettyTCM dt
      , text "ys     =" <+> text (show ys)
      , text "raw    =" <+> text (show display)
      , text "qsToTm =" <+> prettyTCM tqs -- ctx would be permuted form of delta1 ++ delta2
      , text "sub qs =" <+> prettyTCM (applySubst (sub ys wild) tqs)
      ]
    ]

  return display
  where
    -- Note: The upper bound (m - 1) was previously commented out. I
    -- restored it in order to make the substitution finite.
    -- Andreas, 2013-02-28: Who is "I"?
    sub rho wild = parallelS $ map term [0 .. m - 1]
      where
        -- thinking required.. but ignored
        -- dropping the reverse seems to work better
        -- Andreas, 2010-09-09: I DISAGREE.
        -- Ulf, 2011-09-02: Thinking done. Neither was correct.
        -- We had the wrong permutation and we used it incorrectly. Should work now.
        term i = maybe wild var $ findIndex (Just i ==) rho

-- Andreas, 2013-02-28 modeled after Coverage/Match/buildMPatterns
-- The permutation is the one of the original clause.
patsToTerms :: Permutation -> [I.Arg Pattern] -> [I.Arg DisplayTerm]
patsToTerms perm ps = evalState (toTerms ps) xs
  where
    xs   = permute (invertP perm) $ downFrom (size perm)
    tick = do x : xs <- get; put xs; return x

    toTerms :: [I.Arg Pattern] -> State [Nat] [I.Arg DisplayTerm]
    toTerms ps = mapM (T.traverse toTerm) ps

    toTerm :: Pattern -> State [Nat] DisplayTerm
    toTerm p = case p of
      VarP _      -> DTerm . var <$> tick
      DotP t      -> DDot t <$ tick
      ConP c _ ps -> DCon c <$> toTerms ps
      LitP l      -> return $ DTerm (Lit l)

{- OLD
-- Andreas, 2013-02-28: this translation does not take the permutation
-- into account.  I replaced it with a new one (see above).
-- There are so many similar implementations to translate patterns in Agda,
-- opportunity for some refactoring!?

patsToTerms :: [I.Arg Pattern] -> [I.Arg DisplayTerm]
patsToTerms ps = evalState (toTerms ps) 0
  where
    mapMr f xs = reverse <$> mapM f (reverse xs)

    nextVar :: State Nat Nat
    nextVar = do
      i <- get
      put (i + 1)
      return i

    toTerms :: [I.Arg Pattern] -> State Nat [I.Arg DisplayTerm]
    toTerms ps = mapMr toArg ps

    toArg :: I.Arg Pattern -> State Nat (I.Arg DisplayTerm)
    toArg = T.mapM toTerm

    toTerm :: Pattern -> State Nat DisplayTerm
    toTerm p = case p of
      VarP _      -> nextVar >>= \i -> return $ DTerm (var i)
      DotP t      -> return $ DDot t
      ConP c _ ps -> DCon c <$> toTerms ps
      LitP l      -> return $ DTerm (Lit l)
-}
