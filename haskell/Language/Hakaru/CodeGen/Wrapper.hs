{-# LANGUAGE CPP,
             OverloadedStrings,
             DataKinds,
             GADTs,
             KindSignatures #-}

----------------------------------------------------------------
--                                                    2016.06.23
-- |
-- Module      :  Language.Hakaru.CodeGen.Wrapper
-- Copyright   :  Copyright (c) 2016 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  zsulliva@indiana.edu
-- Stability   :  experimental
-- Portability :  GHC-only
--
--   The purpose of the wrapper is to intelligently wrap CStatements
-- into CFunctions and CProgroms to be printed by 'hkc'
--
----------------------------------------------------------------


module Language.Hakaru.CodeGen.Wrapper where

import           Language.Hakaru.Syntax.ABT
import qualified Language.Hakaru.Syntax.AST as T
import           Language.Hakaru.Syntax.TypeCheck
import           Language.Hakaru.Types.Sing

import Language.Hakaru.CodeGen.CodeGenMonad
import Language.Hakaru.CodeGen.Flatten
import Language.Hakaru.CodeGen.HOAS
import Language.Hakaru.Types.DataKind (Hakaru(..))

import           Language.C.Data.Ident
import qualified Language.C.Pretty as C

import           Prelude            as P hiding (unlines)
import           Data.Text          as D
import           Text.PrettyPrint (render)

#if __GLASGOW_HASKELL__ < 710
import           Data.Monoid
#endif
-- import Language.C.Syntax.AST
-- import Language.C.Data.Node

-- | Create program is the top level C codegen. Depending on the type a program
--   will have a different construction. HNat will just return while a measure
--   returns a sampling program.
createProgram :: TypedAST (TrivialABT T.Term) -> Text
createProgram (TypedAST typ abt) =
  let ident         = builtinIdent "result"
      (decls,stmts) = runCodeGen (do declare $ typeDeclaration typ ident
                                     expr <- flattenABT abt
                                     assign ident expr)
  in  unlines [ header typ
              , prelude
              , mainWith typ
                         (fmap (\d -> mconcat [(pack . render . C.pretty) d,";"]) decls)
                         (fmap (pack . render . C.pretty) stmts)
              ]

header :: Sing (a :: Hakaru) -> Text
header (SMeasure _) = unlines [ "#include <time.h>"
                              , "#include <stdlib.h>"
                              , "#include <stdio.h>"
                              , "#include <math.h>" ]
header _            = unlines [ "#include <stdio.h>"
                              , "#include <math.h>" ]

normalC :: Text
normalC = unlines
        [ "double normal(double mu, double sd) {"
        , "  double u = ((double)rand() / (RAND_MAX)) * 2 - 1;"
        , "  double v = ((double)rand() / (RAND_MAX)) * 2 - 1;"
        , "  double r = u*u + v*v;"
        , "  if (r==0 || r>1) return normal(mu,sd);"
        , "  double c = sqrt(-2 * log(r) / r);"
        , "  return mu + u * c * sd;"
        , "}" ]

mainWith :: Sing (a :: Hakaru) -> [Text] -> [Text] -> Text
mainWith typ decl stmts = unlines
 [ "int main(){"
 , case typ of
     SMeasure _ -> "srand(time(NULL));\n"
     _ -> ""
 , unlines decl
 , unlines stmts
 , case typ of
     SMeasure _ -> "while(1) printf(\"%.17g\\n\",result);"
     SInt       -> "printf(\"%d\\n\",result);"
     SNat       -> "printf(\"%d\\n\",result);"
     SProb      -> "printf(\"exp(%.17g)\\n\",result);"
     SReal      -> "printf(\"%.17g\\n\",result);"
     SArray _   -> "printf(\"%.17g\\n\",result);"
     SFun _ _   -> "printf(\"%.17g\\n\",result);"
     SData _ _  -> "printf(\"%.17g\\n\",result);"
 , "return 0;"
 , "}" ]

prelude :: Text
prelude = unlines
 [""]
