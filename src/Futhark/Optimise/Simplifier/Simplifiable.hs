module Futhark.Optimise.Simplifier.Simplifiable
  ( Simplifiable (..)
  , SimpleM
  , bindableSimplifiable
  , simplifyProg
  , simplifyFun
  , simplifyLambda
  )
  where

import Futhark.Representation.AST
import Futhark.MonadFreshNames
import Futhark.Binder
import qualified Futhark.Optimise.Simplifier.Engine as Engine
import Futhark.Optimise.Simplifier.Rule
import Futhark.Representation.Aliases (Aliases)
import Futhark.Optimise.Simplifier.Simple
import Futhark.Representation.AST.Attributes.Ranges

-- | Simplify the given program.  Even if the output differs from the
-- output, meaningful simplification may not have taken place - the
-- order of bindings may simply have been rearranged.
simplifyProg :: (Proper lore, Ranged lore) =>
                Simplifiable (SimpleM lore)
             -> RuleBook (SimpleM lore)
             -> Prog lore
             -> Prog (Aliases lore)
simplifyProg simpl rules prog =
  Prog $ fst $ runSimpleM (mapM Engine.simplifyFun $ progFunctions prog)
               simpl (Engine.emptyEnv rules $ Just prog) namesrc
  where namesrc = newNameSourceForProg prog

-- | Simplify the given function.  Even if the output differs from the
-- output, meaningful simplification may not have taken place - the
-- order of bindings may simply have been rearranged.
simplifyFun :: (MonadFreshNames m, Proper lore, Ranged lore) =>
               Simplifiable (SimpleM lore)
            -> RuleBook (SimpleM lore)
            -> FunDec lore
            -> m (FunDec (Aliases lore))
simplifyFun simpl rules fundec =
  modifyNameSource $ runSimpleM (Engine.simplifyFun fundec) simpl $
  Engine.emptyEnv rules Nothing

-- | Simplify just a single 'Lambda'.
simplifyLambda :: (MonadFreshNames m, Proper lore, Ranged lore) =>
                  Simplifiable (SimpleM lore)
               -> RuleBook (SimpleM lore)
               -> Maybe (Prog lore) -> Lambda lore -> [Maybe Ident]
               -> m (Lambda (Aliases lore))
simplifyLambda simpl rules prog lam args =
  modifyNameSource $ runSimpleM (Engine.simplifyLambda lam args) simpl $
  Engine.emptyEnv rules prog
