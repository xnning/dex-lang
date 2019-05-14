module DeShadow (deShadowPass) where

import Syntax
import Pass
import Fresh
import PPrint
import Util (repeated)

import Data.Foldable
import Control.Monad.Reader

type DeShadowM a = Pass FreshSubst () a

deShadowPass :: UDecl -> TopPass FreshSubst UDecl
deShadowPass decl = case decl of
  UTopLet v expr -> do checkTopShadow v
                       putEnv (newSubst v)
                       liftM (UTopLet v) $ deShadowTop expr
  UTopUnpack v expr -> do checkTopShadow v
                          putEnv (newSubst v)
                          liftM (UTopUnpack v) $ deShadowTop expr
  UEvalCmd NoOp -> return (UEvalCmd NoOp)
  UEvalCmd (Command cmd expr) -> do
    expr' <- deShadowTop expr
    case cmd of Passes -> writeOut $ "\n\nDeshadowed\n" ++ show expr'
                _ -> return ()
    return $ UEvalCmd (Command cmd expr')
  where
    deShadowTop :: UExpr -> TopPass FreshSubst UExpr
    deShadowTop expr = liftTopPass () mempty (deShadowExpr expr)

checkTopShadow :: Var -> TopPass FreshSubst ()
checkTopShadow v = do
  subst <- getEnv
  if isFresh v subst then return ()
                     else throw RepeatedVarErr (pprint v)

deShadowExpr :: UExpr -> DeShadowM UExpr
deShadowExpr expr = case expr of
  ULit x -> return (ULit x)
  UVar v -> liftM UVar $ asks (getRenamed v)
  UBuiltin b -> return (UBuiltin b)
  ULet p bound body -> do
    bound' <- recur bound
    (p', scope) <- freshen p
    body' <- extendWith scope (recur body)
    return $ ULet p' bound' body'
  ULam p body -> do
    (p', scope) <- freshen p
    body' <- extendWith scope (recur body)
    return $ ULam p' body'
  UApp fexpr arg -> liftM2 UApp (recur fexpr) (recur arg)
  UFor b body -> do
    ([b'], scope) <- freshen [b]
    body' <- extendWith scope (recur body)
    return $ UFor b' body'
  UGet e v -> liftM2 UGet (recur e) (asks (getRenamed v))
  UUnpack b bound body -> do
    bound' <- recur bound
    ([b'], scope) <- freshen [b]
    body' <- extendWith scope (recur body)
    return $ UUnpack b' bound' body'
  URecCon r -> liftM URecCon $ traverse recur r
  -- TODO: deshadow type as well when we add scoped type vars
  UAnnot body ty -> liftM (flip UAnnot ty) (recur body)
  where recur = deShadowExpr

freshen :: Traversable f => f Var -> DeShadowM (f Var, FreshSubst)
freshen p = do checkRepeats p
               scope <- ask
               let zipped = fmap (flip rename scope) p
               return (fmap fst zipped, fold (fmap snd zipped))

checkRepeats :: Foldable f => f Var -> DeShadowM ()
checkRepeats xs = case repeated (toList xs) of
                    []  -> return ()
                    xs' -> throw RepeatedVarErr (pprint xs')
