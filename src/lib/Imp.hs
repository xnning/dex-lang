-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE PartialTypeSignatures #-}
{-# OPTIONS_GHC -Wno-partial-type-signatures #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Imp
  ( blockToImpFunction, ImpFunctionWithRecon (..)
  , toImpStandaloneFunction, toImpExportedFunction, ExportCC (..)
  , impFunType, getIType, abstractLinktimeObjects) where

import Prelude hiding ((.), id)
import Data.Functor
import Data.Foldable (toList)
import Data.Text.Prettyprint.Doc (Pretty (..), hardline)
import Control.Category
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.Writer.Strict
import GHC.Exts (inline)

import Err
import MTL1
import Name
import Builder
import Syntax
import CheckType (CheckableE (..))
import Lower (DestBlock)
import LabeledItems
import QueryType
import Util (enumerate, SnocList (..), unsnoc, forMFilter)
import Types.Primitives
import Types.Core
import Types.Imp
import Algebra
import RawName qualified as R

type AtomRecon = Abs (Nest (NameBinder ImpNameC)) SIAtom
type SIAtom   = Atom  SimpToImpIR
type SIType   = Type  SimpToImpIR
type SIBlock  = Block SimpToImpIR
type SIExpr   = Expr  SimpToImpIR
type SIDecl   = Decl  SimpToImpIR
type SIDecls  = Decls SimpToImpIR

-- TODO: make it purely a function of the type and avoid the AtomRecon
blockToImpFunction :: EnvReader m
              => Backend -> CallingConvention
              -> DestBlock n
              -> m n (ImpFunctionWithRecon n)
blockToImpFunction _ cc absBlock = liftImpM $
  translateTopLevel cc absBlock
{-# SCC blockToImpFunction #-}

toImpStandaloneFunction :: EnvReader m => NaryLamExpr SimpIR n -> m n (ImpFunction n)
toImpStandaloneFunction lam = liftImpM $ toImpStandaloneFunction' lam
{-# SCC toImpStandaloneFunction #-}

toImpStandaloneFunction' :: NaryLamExpr SimpIR o -> SubstImpM i o (ImpFunction o)
toImpStandaloneFunction' lam' = do
  lam@(NaryLamExpr bs effs body) <- return $ injectIRE lam'
  case effs of
    Pure -> return ()
    OneEffect IOEffect -> return ()
    _ -> error "effectful functions not implemented"
  ty <- naryLamExprType lam
  AbsPtrs (Abs ptrBinders argResultDest) ptrsInfo <- makeNaryLamDest ty Unmanaged
  let ptrHintTys = [(noHint, PtrType baseTy) | DestPtrInfo baseTy _ <- ptrsInfo]
  dropSubst $ buildImpFunction CInternalFun ptrHintTys \vs -> do
    let substVals = [SubstVal (AtomicIVar (LeftE v) t :: Atom SimpToImpIR _) | (v,t) <- vs]
    argResultDest' <- applySubst (ptrBinders @@> substVals) argResultDest
    (args, resultDest) <- loadArgDests argResultDest'
    extendSubst (bs @@> map SubstVal args) do
      void $ translateBlock (Just $ sink resultDest) body
      return []

-- | Calling convention for exported function.
data ExportCC = FlatExportCC
              | XLAExportCC

data UnpackCC = FlatUnpackCC Int
              | XLAUnpackCC [FormalArg] [FormalArg]

type FormalArg = (NameHint, IType)
type ActualArg n = (ImpName n, IType)

ccPrepareFormals :: ExportCC -> Nest (Binder SimpIR) n l -> [FormalArg] -> ([FormalArg], UnpackCC)
ccPrepareFormals cc args destFormals = case cc of
  FlatExportCC -> do
    (argFormals ++ destFormals, FlatUnpackCC (length argFormals))
  XLAExportCC -> ( [(getNameHint @String "out", i8pp), (getNameHint @String "in", i8pp)]
                 , XLAUnpackCC argFormals destFormals )
  where
    argFormals = nestToList ((noHint,) . (\(BaseTy t) -> t) . binderType) args
    i8pp = PtrType (Heap CPU, PtrType (Heap CPU, Scalar Word8Type))

ccUnpackActuals :: Emits n => UnpackCC -> [(ImpName n, BaseType)] -> SubstImpM i n ([ActualArg n], [ActualArg n])
ccUnpackActuals cc actual = case cc of
  FlatUnpackCC n -> return $ splitAt n actual
  XLAUnpackCC argFormals destFormals -> case actual of
    [outsPtrName, insPtrName] -> do
      let (outsPtr, insPtr) = (IVar (fst outsPtrName) i8pp, IVar (fst insPtrName) i8pp)
      let loadPtr base i pointeeTy =
            flip cast (PtrType (Heap CPU, pointeeTy)) =<< load =<< impOffset base (IIdxRepVal $ fromIntegral i)
      args <- forM (enumerate argFormals) \(i, (_, argTy)) ->
        toArg <$> case argTy of
          PtrType (_, pointeeTy) -> loadPtr insPtr i pointeeTy
          _ -> load =<< loadPtr insPtr i argTy
      -- outsPtr points to the buffer when there's one output, not to the pointer array.
      ptrs <- case destFormals of
        [(_, destTy)] -> (:[]) . toArg <$> cast outsPtr destTy
        _ ->
          forM (enumerate destFormals) \(i, (_, destTy)) ->
            toArg <$> case destTy of
              PtrType (_, pointeeTy) -> loadPtr outsPtr i pointeeTy
              _ -> error "Destination arguments should all have pointer types"
      return (args, ptrs)
    _ -> error "Expected two arguments for the XLA calling convention"
  where
    toArg = \case
      IVar v ty -> (v, ty)
      _ -> error "Expected a variable"
    i8pp = PtrType (Heap CPU, PtrType (Heap CPU, Scalar Word8Type))

toImpExportedFunction :: EnvReader m
                      => ExportCC
                      -> Abs (Nest (Binder SimpIR)) DestBlock n
                      -> (Abs (Nest (Binder SimpIR)) (ListE SBlock) n)
                      -> m n (ImpFunction n)
toImpExportedFunction cc def@(Abs bs (Abs d body)) (Abs baseArgBs argRecons) = liftImpM do
  -- XXX: We assume that makeDest is deterministic in here! We first run it outside of
  -- the Imp function to infer the set of arguments, and then once again inside the
  -- Imp function to get the destination atom. We could pass it around, but it would have
  -- been more complicated.
  ptrFormals <- refreshAbs def \_ (Abs (_:>RawRefTy resTy') _) -> do
    -- WARNING! This ties the makeDest implementation to the C API expected in export.
    -- In particular, every array has to be backend by a single pointer and pairs
    -- should be traversed left-to-right.
    AbsPtrs _ ptrInfo <- makeDest (LLVM, CPU, Unmanaged) $ injectIRE resTy'
    return $ ptrInfo <&> \(DestPtrInfo bt _) -> (noHint, PtrType bt)
  let (ccFormals, ccCtx) = ccPrepareFormals cc baseArgBs ptrFormals
  dropSubst $ buildImpFunction CEntryFun ccFormals \ccActuals -> do
    (args, ptrs) <- ccUnpackActuals ccCtx ccActuals
    argAtoms <- extendSubst (baseArgBs @@> ((SubstVal . actualToAtom) <$> args)) $
      traverse (translateBlock Nothing) $ map injectIRE $ fromListE argRecons
    extendSubst (bs @@> map SubstVal argAtoms) do
      let RawRefTy dTy = injectIRE $ binderType d
      AbsPtrs resDestAbsPtrs _ <- makeDest (LLVM, CPU, Unmanaged) =<< substM dTy
      resDest <- applyNaryAbs resDestAbsPtrs ((SubstVal . actualToAtom) <$> ptrs)
      extendSubst (d @> SubstVal resDest) $
        translateBlock Nothing (injectIRE body) $> []
  where
    actualToAtom :: ActualArg n -> SIAtom n
    actualToAtom (v, t) = AtomicIVar (LeftE v) t
{-# SCC toImpExportedFunction #-}

loadArgDests :: Emits n => NaryLamDest n -> SubstImpM i n ([SIAtom n], Dest n)
loadArgDests (Abs Empty resultDest) = return ([], resultDest)
loadArgDests (Abs (Nest (b:>argDest) bs) resultDest) = do
  arg <- destToAtom argDest
  restDest <- applySubst (b@>SubstVal arg) (Abs bs resultDest)
  (args, resultDest') <- loadArgDests restDest
  return (arg:args, resultDest')

storeArgDests :: Emits n => NaryLamDest n -> [SIAtom n] -> SubstImpM i n (Dest n)
storeArgDests (Abs Empty resultDest) [] = return resultDest
storeArgDests (Abs (Nest (b:>argDest) bs) resultDest) (x:xs) = do
  copyAtom argDest x
  restDest <- applySubst (b@>SubstVal x) (Abs bs resultDest)
  storeArgDests restDest xs
storeArgDests _ _ = error "dest/args mismatch"

data ImpFunctionWithRecon n = ImpFunctionWithRecon (ImpFunction n) (AtomRecon n)

instance GenericE ImpFunctionWithRecon where
  type RepE ImpFunctionWithRecon = PairE ImpFunction AtomRecon
  fromE (ImpFunctionWithRecon fun recon) = PairE fun recon
  {-# INLINE fromE #-}
  toE   (PairE fun recon) = ImpFunctionWithRecon fun recon
  {-# INLINE toE #-}

instance SinkableE ImpFunctionWithRecon
instance SubstE Name ImpFunctionWithRecon
instance CheckableE ImpFunctionWithRecon where
  checkE (ImpFunctionWithRecon f recon) =
    -- TODO: CheckableE instance for the recon too
    ImpFunctionWithRecon <$> checkE f <*> substM recon

instance Pretty (ImpFunctionWithRecon n) where
  pretty (ImpFunctionWithRecon f recon) =
    pretty f <> hardline <> "Reconstruction:" <> hardline <> pretty recon

-- === ImpM monad ===

type ImpBuilderEmissions = RNest ImpDecl

newtype ImpDeclEmission (n::S) (l::S) = ImpDeclEmission (ImpDecl n l)
instance ExtOutMap Env ImpDeclEmission where
  extendOutMap env (ImpDeclEmission d) = env `extendOutMap` toEnvFrag d
  {-# INLINE extendOutMap #-}
instance ExtOutFrag ImpBuilderEmissions ImpDeclEmission where
  extendOutFrag ems (ImpDeclEmission d) = RNest ems d
  {-# INLINE extendOutFrag #-}

newtype ImpM (n::S) (a:: *) =
  ImpM { runImpM' :: WriterT1 (ListE IExpr)
                       (InplaceT Env ImpBuilderEmissions HardFailM) n a }
  deriving ( Functor, Applicative, Monad, ScopeReader, Fallible, MonadFail)

type SubstImpM = SubstReaderT (AtomSubstVal SimpToImpIR) ImpM :: S -> S -> * -> *

instance ExtOutMap Env ImpBuilderEmissions where
  extendOutMap bindings emissions =
    bindings `extendOutMap` toEnvFrag emissions

class (ImpBuilder2 m, SubstReader (AtomSubstVal SimpToImpIR) m, EnvReader2 m, EnvExtender2 m)
      => Imper (m::MonadKind2) where

instance EnvReader ImpM where
  unsafeGetEnv = ImpM $ lift11 $ getOutMapInplaceT

instance EnvExtender ImpM where
  refreshAbs ab cont = ImpM $ lift11 $
    refreshAbs ab \b e -> do
      (result, ptrs) <- runWriterT1 $ runImpM' $ cont b e
      case ptrs of
        ListE [] -> return result
        _ -> error "shouldn't be able to emit pointers without `Mut`"

instance ImpBuilder ImpM where
  emitMultiReturnInstr instr = do
    Distinct <- getDistinct
    tys <- impInstrTypes instr
    -- The three cases below are all equivalent, but 0- and 1-return instructions
    -- are so common that it's worth spelling their cases out explicitly to enable
    -- more GHC optimizations.
    ImpM $ lift11 case tys of
      []   -> do
        extendTrivialSubInplaceT $ ImpDeclEmission $ ImpLet Empty instr
        return NoResults
      [ty] -> do
        OneResult <$> freshExtendSubInplaceT noHint \b ->
          (ImpDeclEmission $ ImpLet (Nest (IBinder b ty) Empty) instr, IVar (binderName b) ty)
      _ -> do
        Abs bs vs <- return $ newNames $ length tys
        let impBs = makeImpBinders bs tys
        let decl = ImpLet impBs instr
        ListE vs' <- extendInplaceT $ Abs (RNest REmpty decl) vs
        return $ MultiResult $ zipWith IVar vs' tys
    where
     makeImpBinders :: Nest (NameBinder ImpNameC) n l -> [IType] -> Nest IBinder n l
     makeImpBinders Empty [] = Empty
     makeImpBinders (Nest b bs) (ty:tys) = Nest (IBinder b ty) $ makeImpBinders bs tys
     makeImpBinders _ _ = error "zip error"

  buildScopedImp cont = ImpM $ WriterT1 \w ->
    liftM (, w) do
      Abs rdecls e <- locallyMutableInplaceT do
        Emits <- fabricateEmitsEvidenceM
        (result, (ListE ptrs)) <- runWriterT1 $ runImpM' do
           Distinct <- getDistinct
           cont
        _ <- runWriterT1 $ runImpM' do
          forM ptrs \ptr -> emitStatement $ Free ptr
        return result
      return $ Abs (unRNest rdecls) e

  extendAllocsToFree ptr = ImpM $ tell $ ListE [ptr]
  {-# INLINE extendAllocsToFree #-}

instance ImpBuilder m => ImpBuilder (SubstReaderT (AtomSubstVal SimpToImpIR) m i) where
  emitMultiReturnInstr instr = SubstReaderT $ lift $ emitMultiReturnInstr instr
  {-# INLINE emitMultiReturnInstr #-}
  buildScopedImp cont = SubstReaderT $ ReaderT \env ->
    buildScopedImp $ runSubstReaderT (sink env) $ cont
  {-# INLINE buildScopedImp #-}
  extendAllocsToFree ptr = SubstReaderT $ lift $ extendAllocsToFree ptr
  {-# INLINE extendAllocsToFree #-}

instance ImpBuilder m => Imper (SubstReaderT (AtomSubstVal SimpToImpIR) m)

liftImpM :: EnvReader m => SubstImpM n n a -> m n a
liftImpM cont = do
  env <- unsafeGetEnv
  Distinct <- getDistinct
  case runHardFail $ runInplaceT env $ runWriterT1 $
         runImpM' $ runSubstReaderT idSubst $ cont of
    (REmpty, (result, ListE [])) -> return result
    _ -> error "shouldn't be possible because of `Emits` constraint"

-- === the actual pass ===

-- We don't emit any results when a destination is provided, since they are already
-- going to be available through the dest.
translateTopLevel :: CallingConvention
                  -> DestBlock i
                  -> SubstImpM i o (ImpFunctionWithRecon o)
translateTopLevel cc (Abs (destb:>destTy') body') = do
  destTy <- return $ injectIRE destTy'
  body   <- return $ injectIRE body'
  ab  <- buildScopedImp do
    dest <- case destTy of
      RawRefTy ansTy -> makeAllocDest Unmanaged =<< substM ansTy
      _ -> error "Expected a reference type for body destination"
    extendSubst (destb @> SubstVal dest) $ void $ translateBlock Nothing body
    destToAtom dest
  refreshAbs ab \decls resultAtom -> do
    (results, recon) <- buildRecon decls resultAtom
    let funImpl = Abs Empty $ ImpBlock decls results
    let funTy   = IFunType cc [] (map getIType results)
    return $ ImpFunctionWithRecon (ImpFunction funTy funImpl) recon

buildRecon :: (HoistableB b, EnvReader m)
           => b n l
           -> SIAtom l
           -> m l ([IExpr l], AtomRecon n)
buildRecon b x = do
  let (vs, recon) = captureClosure b x
  xs <- forM vs \v -> IVar v <$> impVarType v
  return (xs, recon)

impVarType :: EnvReader m => ImpName n -> m n BaseType
impVarType v = do
  ~(ImpNameBinding ty) <- lookupEnv v
  return ty
{-# INLINE impVarType #-}

translateBlock :: forall i o. Emits o
               => MaybeDest o -> SIBlock i -> SubstImpM i o (SIAtom o)
translateBlock dest (Block _ decls result) = translateDeclNest decls $ translateExpr dest $ Atom result

translateDeclNestSubst
  :: Emits o => Subst (AtomSubstVal SimpToImpIR) l o
  -> Nest SIDecl l i' -> SubstImpM i o (Subst (AtomSubstVal SimpToImpIR) i' o)
translateDeclNestSubst !s = \case
  Empty -> return s
  Nest (Let b (DeclBinding _ _ expr)) rest -> do
    x <- withSubst s $ translateExpr Nothing expr
    translateDeclNestSubst (s <>> (b@>SubstVal x)) rest

translateDeclNest :: Emits o => Nest SIDecl i i' -> SubstImpM i' o a -> SubstImpM i o a
translateDeclNest decls cont = do
  s  <- getSubst
  s' <- translateDeclNestSubst s decls
  withSubst s' cont
{-# INLINE translateDeclNest #-}

translateExpr :: Emits o => MaybeDest o -> SIExpr i -> SubstImpM i o (SIAtom o)
translateExpr maybeDest expr = confuseGHC >>= \_ -> case expr of
  Hof hof -> toImpHof maybeDest hof
  App f' xs' -> do
    f <- substM f'
    xs <- mapM substM xs'
    case f of
      Var v -> lookupAtomName v >>= \case
        TopFunBound _ (FFITopFun v') -> do
          resultTy <- getType $ App f xs
          scalarArgs <- liftM toList $ mapM fromScalarAtom xs
          results <- impCall v' scalarArgs
          restructureScalarOrPairType resultTy results
        TopFunBound piTy (SpecializedTopFun specializationSpec) -> do
          if length (toList xs') /= numNaryPiArgs piTy
            then notASimpExpr
            else case specializationSpec of
              AppSpecialization _ _ -> do
                Just fImp <- queryImpCache v
                result <- emitCall piTy fImp $ toList xs
                returnVal result
        _ -> notASimpExpr
      _ -> notASimpExpr
  TabApp f' xs' -> do
    f <- substM f'
    xs <- mapM substM xs'
    case fromNaryTabLamExact (length xs) f of
      Just (NaryLamExpr bs _ body) -> do
        let subst = bs @@> fmap SubstVal xs
        body' <- applySubst subst body
        dropSubst $ translateBlock maybeDest body'
      _ -> notASimpExpr
  Atom x -> substM x >>= returnVal
  -- Inlining the traversal helps GHC sink the substM below the case inside toImpOp.
  Op op -> (inline traversePrimOp) substM op >>= toImpOp maybeDest
  Case e alts ty _ -> do
    e' <- substM e
    case trySelectBranch e' of
      Just (con, arg) -> do
        Abs b body <- return $ alts !! con
        extendSubst (b @> SubstVal arg) $ translateBlock maybeDest body
      Nothing -> case e' of
        Con (Newtype (VariantTy _) (Con (SumAsProd _ tag xss))) -> go tag xss
        Con (Newtype (TypeCon _ _ _) (Con (SumAsProd _ tag xss))) -> go tag xss
        Con (SumAsProd _ tag xss) -> go tag xss
        _ -> error $ "unexpected case scrutinee: " ++ pprint e'
        where
          go tag xss = do
            tag' <- fromScalarAtom tag
            dest <- allocDest maybeDest =<< substM ty
            emitSwitch tag' (zip xss alts) $
              \(xs, Abs b body) ->
                 void $ extendSubst (b @> SubstVal (sink xs)) $
                   translateBlock (Just $ sink dest) body
            destToAtom dest
  Handle _ _ _ -> error "handlers should be gone by now"
  where
    notASimpExpr = error $ "not a simplified expression: " ++ pprint expr
    returnVal atom = case maybeDest of
      Nothing   -> return atom
      Just dest -> copyAtom dest atom >> return atom

toImpOp :: forall i o .
           Emits o => MaybeDest o -> PrimOp (SIAtom o) -> SubstImpM i o (SIAtom o)
toImpOp maybeDest op = case op of
  TabCon ty rows -> do
    TabPi (TabPiType b _) <- return ty
    let ixTy = binderAnn b
    resultTy <- resultTyM
    dest <- allocDest maybeDest resultTy
    forM_ (zip [0..] rows) \(i, row) -> do
      ithDest <- destGet dest =<< unsafeFromOrdinalImp ixTy (IIdxRepVal i)
      copyAtom ithDest row
    destToAtom dest
  PrimEffect refDest m -> do
    case m of
      MAsk -> returnVal =<< destToAtom refDest
      MExtend (BaseMonoid _ combine) x -> do
        xTy <- getType x
        refVal <- destToAtom refDest
        result <- liftBuilderImp $
                    liftMonoidCombine (sink xTy) (sink combine) (sink refVal) (sink x)
        copyAtom refDest result
        returnVal UnitVal
      MPut x -> copyAtom refDest x >> returnVal UnitVal
      MGet -> do
        resultTy <- resultTyM
        dest <- allocDest maybeDest resultTy
        -- It might be more efficient to implement a specialized copy for dests
        -- than to go through a general purpose atom.
        copyAtom dest =<< destToAtom refDest
        destToAtom dest
    where
      liftMonoidCombine :: Emits n => SIType n -> SIAtom n -> SIAtom n -> SIAtom n -> SBuilderM n (SIAtom n)
      liftMonoidCombine accTy bc x y = do
        Pi baseCombineTy <- getType bc
        let baseTy = argType baseCombineTy
        alphaEq accTy baseTy >>= \case
          -- Immediately beta-reduce, beacuse Imp doesn't reduce non-table applications.
          True -> do
            Lam (BinaryLamExpr xb yb body) <- return bc
            body' <- applySubst (xb @> SubstVal x <.> yb @> SubstVal y) body
            emitBlock body'
          False -> case accTy of
            TabTy (b:>ixTy) eltTy -> do
              buildFor noHint Fwd ixTy \i -> do
                xElt <- tabApp (sink x) (Var i)
                yElt <- tabApp (sink y) (Var i)
                eltTy' <- applySubst (b@>i) eltTy
                liftMonoidCombine eltTy' (sink bc) xElt yElt
            _ -> error $ "Base monoid type mismatch: can't lift " ++
                   pprint baseTy ++ " to " ++ pprint accTy
  IndexRef refDest i -> returnVal =<< destGet refDest i
  ProjRef i ~(Con (ConRef (ProdCon refs))) -> returnVal $ refs !! i
  IOAlloc ty n -> do
    ptr <- emitAlloc (Heap CPU, ty) =<< fromScalarAtom n
    returnVal =<< toScalarAtom ptr
  IOFree ptr -> do
    ptr' <- fromScalarAtom ptr
    emitStatement $ Free ptr'
    return UnitVal
  PtrOffset arr (IdxRepVal 0) -> returnVal arr
  PtrOffset arr off -> do
    arr' <- fromScalarAtom arr
    off' <- fromScalarAtom off
    buf <- impOffset arr' off'
    returnVal =<< toScalarAtom buf
  PtrLoad arr ->
    returnVal =<< toScalarAtom =<< loadAnywhere =<< fromScalarAtom arr
  PtrStore ptr x -> do
    ptr' <- fromScalarAtom ptr
    x'   <- fromScalarAtom x
    store ptr' x'
    return UnitVal
  ThrowError _ -> do
    resultTy <- resultTyM
    dest <- allocDest maybeDest resultTy
    emitStatement IThrowError
    -- XXX: we'd be reading uninitialized data here but it's ok because control never reaches
    -- this point since we just threw an error.
    destToAtom dest
  CastOp destTy x -> do
    sourceTy <- getType x
    case (sourceTy, destTy) of
      (BaseTy _, BaseTy bt) -> do
        x' <- fromScalarAtom x
        returnVal =<< toScalarAtom =<< cast x' bt
      _ -> error $ "Invalid cast: " ++ pprint sourceTy ++ " -> " ++ pprint destTy
  BitcastOp destTy x -> do
    case destTy of
      BaseTy bt -> do
        x' <- fromScalarAtom x
        ans <- emitInstr $ IBitcastOp bt x'
        returnVal =<< toScalarAtom ans
      _ -> error "Invalid bitcast"
  Select p x y -> do
    xTy <- getType x
    case xTy of
      BaseTy _ -> do
        p' <- fromScalarAtom p
        x' <- fromScalarAtom x
        y' <- fromScalarAtom y
        ans <- emitInstr $ IPrimOp $ Select p' x' y'
        returnVal =<< toScalarAtom ans
      _ -> unsupported
  SumTag con -> case con of
    Con (SumCon _ tag _) -> returnVal $ TagRepVal $ fromIntegral tag
    Con (SumAsProd _ tag _) -> returnVal tag
    Con (Newtype _ (Con (SumCon _ tag _))) -> returnVal $ TagRepVal $ fromIntegral tag
    Con (Newtype _ (Con (SumAsProd _ tag _))) -> returnVal tag
    _ -> error $ "Not a data constructor: " ++ pprint con
  ToEnum ty i -> returnVal =<< case ty of
    TypeCon _ defName _ -> do
      DataDef _ _ cons <- lookupDataDef defName
      return $ Con $ Newtype ty $
        Con $ SumAsProd (cons <&> const UnitTy) i (cons <&> const UnitVal)
    VariantTy (NoExt labeledItems) -> do
      let items = toList labeledItems
      return $ Con $ Newtype ty $
        Con $ SumAsProd (items <&> const UnitTy) i (items <&> const UnitVal)
    SumTy cases ->
      return $ Con $ SumAsProd cases i $ cases <&> const UnitVal
    _ -> error $ "Not an enum: " ++ pprint ty
  SumToVariant c -> do
    resultTy <- resultTyM
    return $ Con $ Newtype resultTy $ c
  AllocDest ty  -> returnVal =<< alloc ty
  Place ref val -> copyAtom ref val >> returnVal UnitVal
  Freeze ref -> destToAtom ref
  -- Listing branches that should be dead helps GHC cut down on code size.
  ThrowException _        -> unsupported
  RecordCons _ _          -> unsupported
  RecordSplit _ _         -> unsupported
  RecordConsDynamic _ _ _ -> unsupported
  RecordSplitDynamic _ _  -> unsupported
  VariantLift _ _         -> unsupported
  VariantSplit _ _        -> unsupported
  ProjMethod _ _          -> unsupported
  ExplicitApply _ _       -> unsupported
  VectorBroadcast val vty -> do
    val' <- fromScalarAtom val
    emitInstr (IVectorBroadcast val' $ toIVectorType vty) >>= toScalarAtom >>= returnVal
  VectorIota vty -> emitInstr (IVectorIota $ toIVectorType vty) >>= toScalarAtom >>= returnVal
  VectorSubref ref i vty -> do
    Con (BaseTypeRef refi) <- liftBuilderImp $ indexDest (sink ref) (sink i)
    refi' <- fromScalarAtom refi
    let PtrType (addrSpace, _) = getIType refi'
    returnVal =<< case vty of
      BaseTy vty'@(Vector _ _) -> do
        Con . BaseTypeRef <$> (toScalarAtom =<< cast refi' (PtrType (addrSpace, vty')))
      _ -> error "Expected a vector type"
  _ -> do
    instr <- IPrimOp <$> (inline traversePrimOp) fromScalarAtom op
    emitInstr instr >>= toScalarAtom >>= returnVal
  where
    unsupported = error $ "Unsupported PrimOp encountered in Imp" ++ pprint op
    resultTyM :: SubstImpM i o (SIType o)
    resultTyM = getType $ Op op
    returnVal atom = case maybeDest of
      Nothing   -> return atom
      Just dest -> copyAtom dest atom >> return atom

toImpHof :: Emits o => Maybe (Dest o) -> PrimHof (SIAtom i) -> SubstImpM i o (SIAtom o)
toImpHof maybeDest hof = do
  resultTy <- getTypeSubst (Hof hof)
  case hof of
    For d ixDict (Lam (LamExpr b body)) -> do
      ixTy <- ixTyFromDict =<< substM ixDict
      n <- indexSetSizeImp ixTy
      dest <- allocDest maybeDest resultTy
      emitLoop (getNameHint b) d n \i -> do
        idx <- unsafeFromOrdinalImp (sink ixTy) i
        ithDest <- destGet (sink dest) idx
        void $ extendSubst (b @> SubstVal idx) $
          translateBlock (Just ithDest) body
      destToAtom dest
    While (Lam (LamExpr b body)) -> do
      body' <- buildBlockImp $ extendSubst (b@>SubstVal UnitVal) do
        ans <- fromScalarAtom =<< translateBlock Nothing body
        return [ans]
      emitStatement $ IWhile body'
      return UnitVal
    RunReader r (Lam (BinaryLamExpr h ref body)) -> do
      r' <- substM r
      rDest <- alloc =<< getType r'
      copyAtom rDest r'
      extendSubst (h @> SubstVal UnitTy <.> ref @> SubstVal rDest) $
        translateBlock maybeDest body
    RunWriter d (BaseMonoid e _) (Lam (BinaryLamExpr h ref body)) -> do
      let PairTy ansTy accTy = resultTy
      (aDest, wDest) <- case d of
        Nothing -> destPairUnpack <$> allocDest maybeDest resultTy
        Just d' -> (,) <$> allocDest Nothing ansTy <*> substM d'
      e' <- substM e
      emptyVal <- liftBuilderImp do
        PairE accTy' e'' <- sinkM $ PairE accTy e'
        liftMonoidEmpty accTy' e''
      copyAtom wDest emptyVal
      void $ extendSubst (h @> SubstVal UnitTy <.> ref @> SubstVal wDest) $
        translateBlock (Just aDest) body
      PairVal <$> destToAtom aDest <*> destToAtom wDest
    RunState d s (Lam (BinaryLamExpr h ref body)) -> do
      let PairTy ansTy _ = resultTy
      (aDest, sDest) <- case d of
        Nothing -> destPairUnpack <$> allocDest maybeDest resultTy
        Just d' -> (,) <$> allocDest Nothing ansTy <*> substM d'
      copyAtom sDest =<< substM s
      void $ extendSubst (h @> SubstVal UnitTy <.> ref @> SubstVal sDest) $
        translateBlock (Just aDest) body
      PairVal <$> destToAtom aDest <*> destToAtom sDest
    RunIO (Lam (LamExpr b body)) ->
      extendSubst (b@>SubstVal UnitVal) $
        translateBlock maybeDest body
    RunInit (Lam (LamExpr b body)) ->
      extendSubst (b@>SubstVal UnitVal) $
        translateBlock maybeDest body
    Seq d ixDict carry (Lam (LamExpr b body)) -> do
      ixTy <- ixTyFromDict =<< substM ixDict
      carry' <- substM carry
      n <- indexSetSizeImp ixTy
      emitLoop (getNameHint b) d n \i -> do
        idx <- unsafeFromOrdinalImp (sink ixTy) i
        void $ extendSubst (b @> SubstVal (PairVal idx (sink carry'))) $
          translateBlock Nothing body
      case maybeDest of
        Nothing -> return carry'
        Just _  -> error "Unexpected dest"
    RememberDest d (Lam (LamExpr b body)) -> do
      d' <- substM d
      void $ extendSubst (b @> SubstVal d') $ translateBlock Nothing body
      return d'
    _ -> error $ "not implemented: " ++ pprint hof
    where
      liftMonoidEmpty :: SIType n -> SIAtom n -> SBuilderM n (SIAtom n)
      liftMonoidEmpty accTy x = do
        xTy <- getType x
        alphaEq xTy accTy >>= \case
          True -> return x
          False -> case accTy of
            TabTy (b:>ixTy) eltTy -> do
              buildTabLam noHint ixTy \i -> do
                x' <- sinkM x
                ab <- sinkM $ Abs b eltTy
                eltTy' <- applyAbs ab i
                liftMonoidEmpty eltTy' x'
            _ -> error $ "Base monoid type mismatch: can't lift " ++
                  pprint xTy ++ " to " ++ pprint accTy


-- === Destination builder monad ===

-- It's shame to have to reimplement so much for this DestM monad. The problem
-- is that `makeDestRec` is emitting two sorts of names: (1) decls to compute
-- indexing offsets (often under a table lambda) and (2) pointer names, with
-- sizes, for the buffers themselves. The emissions are interleaved, but we're
-- really dealing with two separate scopes: the pointer binders are always
-- hoistable above the decls. Ideally we'd have a system with two scope
-- parameters, where you can separately emit into either. The types would then
-- look like this:

--   makeDestRec :: Idxs n -> Abs IdxNest SIType n -> DestM n l (Dest l)
--   emitDecl    :: Expr  l -> DestM n l (AtomName l)
--   emitPointer :: Block n -> DestM n l (AtomName n)

data DestPtrInfo n = DestPtrInfo PtrType (SIBlock n)
type PtrBinders  = Nest  AtomNameBinder
type RPtrBinders = RNest AtomNameBinder
data DestEmissions n l where
  DestEmissions
    :: {-# UNPACK #-} !(DestPtrEmissions n h)  -- pointers to allocate
    ->                !(RNest SIDecl h l)       -- decls to compute indexing offsets
    -> DestEmissions n l

instance GenericB DestEmissions where
  type RepB DestEmissions = DestPtrEmissions `PairB` RNest SIDecl
  fromB (DestEmissions bs ds) = bs `PairB` ds
  {-# INLINE fromB #-}
  toB   (bs `PairB` ds) = DestEmissions bs ds
  {-# INLINE toB #-}
instance ProvesExt   DestEmissions
instance BindsNames  DestEmissions
instance SinkableB DestEmissions
instance SubstB Name DestEmissions
instance HoistableB  DestEmissions

instance BindsEnv DestEmissions where
  toEnvFrag (DestEmissions ptrs decls) =
    withSubscopeDistinct decls $
      toEnvFrag ptrs `catEnvFrags` toEnvFrag decls

instance ExtOutMap Env DestEmissions where
  extendOutMap bindings emissions = bindings `extendOutMap` toEnvFrag emissions

instance OutFrag DestEmissions where
  emptyOutFrag = emptyDestEmissions
  {-# INLINE emptyOutFrag #-}
  catOutFrags _ = catDestEmissions
  {-# INLINE catOutFrags #-}

emptyDestEmissions :: DestEmissions n n
emptyDestEmissions = DestEmissions emptyOutFrag REmpty
{-# NOINLINE [1] emptyDestEmissions #-}

catDestEmissions :: Distinct l => DestEmissions n h -> DestEmissions h l -> DestEmissions n l
catDestEmissions (DestEmissions ptrs1 d1) (DestEmissions ptrs2 d2) =
  case withSubscopeDistinct d2 $ ignoreHoistFailure $ exchangeBs $ PairB d1 ptrs2 of
    PairB ptrs2' d1' -> DestEmissions (ptrs1 >>> ptrs2') (d1' >>> d2)
{-# NOINLINE [1] catDestEmissions #-}
{-# RULES
      "catDestEmissions Empty *"  forall e. catDestEmissions emptyDestEmissions e = e;
      "catDestEmissions * Empty"  forall e. catDestEmissions e emptyDestEmissions = e;
      "catDestEmissions reassoc"  forall e1 e2 e3. catDestEmissions e1 (catDestEmissions e2 e3) = withSubscopeDistinct e3 (catDestEmissions (catDestEmissions e1 e2) e3)
  #-}

newtype DestDeclEmissions (n::S) (l::S)
  = DestDeclEmissions (SIDecl n l)
  deriving (ProvesExt, BindsNames, SinkableB, SubstB Name)
instance ExtOutMap Env DestDeclEmissions where
  extendOutMap env (DestDeclEmissions decl) = env `extendOutMap` toEnvFrag decl
instance ExtOutFrag DestEmissions DestDeclEmissions where
  extendOutFrag (DestEmissions p d) (DestDeclEmissions d') = DestEmissions p $ RNest d d'
  {-# INLINE extendOutFrag #-}

data DestPtrEmissions (n::S) (l::S)
  = DestPtrEmissions (SnocList (DestPtrInfo n))  -- pointer types and allocation sizes
                     (RPtrBinders n l)           -- pointer binders for allocations we require

instance GenericB DestPtrEmissions where
  type RepB DestPtrEmissions = LiftB (ListE DestPtrInfo) `PairB` RPtrBinders
  fromB (DestPtrEmissions (ReversedList i) b) = (LiftB (ListE i)) `PairB` b
  toB   ((LiftB (ListE i)) `PairB` b) = DestPtrEmissions (ReversedList i) b
instance ProvesExt   DestPtrEmissions
instance BindsNames  DestPtrEmissions
instance SinkableB   DestPtrEmissions
instance HoistableB  DestPtrEmissions
instance SubstB Name DestPtrEmissions

instance Category DestPtrEmissions where
  id = DestPtrEmissions mempty emptyOutFrag
  (DestPtrEmissions i2 b2) . (DestPtrEmissions i1 b1) = DestPtrEmissions i' b'
    where
      i' = i1 <> (ReversedList $ fromListE $ ignoreHoistFailure $ hoist b1 $ ListE $ fromReversedList i2)
      b' = b1 >>> b2
  {-# INLINE (.) #-}
instance OutFrag DestPtrEmissions where
  emptyOutFrag = id
  {-# INLINE emptyOutFrag #-}
  catOutFrags _ = (>>>)
  {-# INLINE catOutFrags #-}

instance BindsEnv DestPtrEmissions where
  toEnvFrag (DestPtrEmissions ptrInfo ptrs) = ptrBindersToEnvFrag ptrInfo ptrs
    where
      ptrBindersToEnvFrag :: Distinct l => SnocList (DestPtrInfo n) -> RNest AtomNameBinder n l -> EnvFrag n l
      ptrBindersToEnvFrag (ReversedList []) REmpty = emptyOutFrag
      ptrBindersToEnvFrag (ReversedList (DestPtrInfo ty _ : rest)) (RNest restBs b) =
        withSubscopeDistinct b do
          let frag1 = toEnvFrag $ b :> PtrTy ty
          let frag2 = withExtEvidence (toExtEvidence b) $
                         ptrBindersToEnvFrag (ReversedList rest) restBs
          frag2 `catEnvFrags` frag1
      ptrBindersToEnvFrag _ _ = error "mismatched indices"

instance ExtOutFrag DestEmissions DestPtrEmissions where
  extendOutFrag (DestEmissions ptrs d) emissions =
    case ignoreHoistFailure $ exchangeBs $ PairB d emissions of
      PairB emissions' d' -> DestEmissions (ptrs >>> emissions') d'
  {-# INLINE extendOutFrag #-}

instance ExtOutMap Env DestPtrEmissions where
  extendOutMap bindings emissions = bindings `extendOutMap` toEnvFrag emissions


newtype DestM (n::S) (a:: *) =
  DestM { runDestM' :: (InplaceT Env DestEmissions
                         (ReaderT AllocInfo HardFailM)) n a }
  deriving ( Functor, Applicative, Monad, MonadFail
           , ScopeReader, Fallible, EnvReader, EnvExtender )

liftDestM :: forall m n a. EnvReader m
          => AllocInfo
          -> DestM n a
          -> m n a
liftDestM allocInfo m = do
  env <- unsafeGetEnv
  Distinct <- getDistinct
  let result = runHardFail $ flip runReaderT allocInfo $
                 runInplaceT env $ runDestM' m
  case result of
    (DestEmissions (DestPtrEmissions (ReversedList []) REmpty) REmpty, result') -> return result'
    _ -> error "not implemented"
{-# INLINE liftDestM #-}

getAllocInfo :: DestM n AllocInfo
getAllocInfo = DestM $ lift1 ask
{-# INLINE getAllocInfo #-}

introduceNewPtr :: Mut n => NameHint -> PtrType -> SIBlock n -> DestM n (SAtomName n)
introduceNewPtr hint ptrTy numel =
  DestM $ freshExtendSubInplaceT hint \b ->
    (DestPtrEmissions (ReversedList [DestPtrInfo ptrTy numel]) $ RNest REmpty b, binderName b)

buildLocalDest
  :: (SinkableE e)
  => (forall l. (Mut l, DExt n l) => DestM l (e l))
  -> DestM n (AbsPtrs e n)
buildLocalDest cont = do
  Abs (DestEmissions (DestPtrEmissions ptrInfo ptrBs) decls) e <-
    DestM do
      Abs bs e <- locallyMutableInplaceT $ runDestM' cont
      return $ Abs bs e
  case decls of
    REmpty -> return $ AbsPtrs (Abs (unRNest ptrBs) e) $ unsnoc ptrInfo
    _ -> error "shouldn't have decls without `Emits`"

-- TODO: this is mostly copy-paste from Inference
buildDeclsDest
  :: (Mut n, SubstE Name e, SinkableE e)
  => (forall l. (Emits l, DExt n l) => DestM l (e l))
  -> DestM n (Abs (Nest SIDecl) e n)
buildDeclsDest cont = do
  DestM do
    Abs (DestEmissions ptrs decls) result <- locallyMutableInplaceT do
      Emits <- fabricateEmitsEvidenceM
      runDestM' cont
    Abs decls' e <- extendSubInplaceT $ Abs ptrs $ Abs decls result
    return $ Abs (unRNest decls') e
{-# INLINE buildDeclsDest #-}

buildBlockDest
  :: Mut n
  => (forall l. (Emits l, DExt n l) => DestM l (SIAtom l))
  -> DestM n (SIBlock n)
buildBlockDest cont = buildDeclsDest (cont >>= withType) >>= computeAbsEffects >>= absToBlock
{-# INLINE buildBlockDest #-}

-- TODO: this is mostly copy-paste from Inference
buildAbsDest
  :: (SinkableE e, SubstE Name e, HoistableE e, Color c, ToBinding binding c)
  => Mut n
  => NameHint -> binding n
  -> (forall l. (Mut l, DExt n l) => Name c l -> DestM l (e l))
  -> DestM n (Abs (BinderP c binding) e n)
buildAbsDest hint binding cont = DestM do
  resultWithEmissions <- withFreshBinder hint binding \b -> do
    ab <- locallyMutableInplaceT do
      runDestM' $ cont $ sink $ binderName b
    refreshAbs ab \emissions result -> do
      PairB emissions' b' <- liftHoistExcept $ exchangeBs $ PairB b emissions
      return $ Abs emissions' $ Abs b' result
  Abs b e <- extendInplaceT resultWithEmissions
  return $ Abs (b:>binding) e

-- decls emitted at the inner scope are hoisted to the outer scope
-- (they must be hoistable, otherwise we'll get a hoisting error)
buildAbsHoistingDeclsDest
  :: (SinkableE e, SubstE Name e, HoistableE e, Color c, ToBinding binding c)
  => Emits n
  => NameHint -> binding n
  -> (forall l. (Emits l, DExt n l) => Name c l -> DestM l (e l))
  -> DestM n (Abs (BinderP c binding) e n)
buildAbsHoistingDeclsDest hint binding cont =
  -- XXX: here we're using the fact that `buildAbsDest` doesn't actually check
  -- that the function produces no decls (it assumes it can't because it doesn't
  -- give it `Emits`) and so it just hoists all the emissions.
  buildAbsDest hint binding \v -> do
    Emits <- fabricateEmitsEvidenceM
    cont v

buildTabLamDest
  :: Mut n
  => NameHint -> IxType SimpToImpIR n
  -> (forall l. (Emits l, DExt n l) => SAtomName l -> DestM l (SIAtom l))
  -> DestM n (SIAtom n)
buildTabLamDest hint ty cont = do
  Abs (b:>_) body <- buildAbsDest hint ty \v ->
    buildBlockDest $ sinkM v >>= cont
  return $ TabLam $ TabLamExpr (b:>ty) body

instance Builder SimpToImpIR DestM where
  emitDecl hint ann expr = do
    ty <- getType expr
    DestM $ freshExtendSubInplaceT hint \b ->
      (DestDeclEmissions $ Let b $ DeclBinding ann ty expr, binderName b)
  {-# INLINE emitDecl #-}

instance GenericE DestPtrInfo where
  type RepE DestPtrInfo = PairE (LiftE PtrType) SIBlock
  fromE (DestPtrInfo ty n) = PairE (LiftE ty) n
  toE   (PairE (LiftE ty) n) = DestPtrInfo ty n

instance SinkableE DestPtrInfo
instance HoistableE  DestPtrInfo
instance SubstE Name DestPtrInfo
instance SubstE (AtomSubstVal SimpToImpIR) DestPtrInfo

-- === Destination builder ===

type Dest = SIAtom  -- has type `Ref a` for some a
type MaybeDest n = Maybe (Dest n)

data AbsPtrs e n = AbsPtrs (Abs PtrBinders e n) [DestPtrInfo n]

instance GenericE (AbsPtrs e) where
  type RepE (AbsPtrs e) = PairE (NaryAbs AtomNameC e) (ListE DestPtrInfo)
  fromE (AbsPtrs ab ptrInfo) = PairE ab (ListE ptrInfo)
  toE   (PairE ab (ListE ptrInfo)) = AbsPtrs ab ptrInfo

instance SinkableE e => SinkableE (AbsPtrs e)
instance HoistableE e => HoistableE (AbsPtrs e)
instance SubstE Name e => SubstE Name (AbsPtrs e)
instance SubstE (AtomSubstVal SimpToImpIR) e => SubstE (AtomSubstVal SimpToImpIR) (AbsPtrs e)

-- builds a dest and a list of pointer binders along with their required allocation sizes
makeDest :: AllocInfo -> SIType n -> SubstImpM i n (AbsPtrs Dest n)
makeDest allocInfo ty =
  liftDestM allocInfo $ buildLocalDest $ makeSingleDest [] $ sink ty
{-# SCC makeDest #-}

makeSingleDest :: Mut n => [SAtomName n] -> SIType n -> DestM n (Dest n)
makeSingleDest depVars ty = do
  Abs decls dest <- buildDeclsDest $
    makeDestRec (Abs Empty UnitE, []) (map sink depVars) (sink ty)
  case decls of
    Empty -> return dest
    _ -> error
     $ "shouldn't need to emit decls if we're not working with indices"
     ++ pprint decls

extendIdxsTy
  :: EnvReader m
  => DestIdxs n -> IxType SimpToImpIR n -> m n (EmptyAbs IdxNest n)
extendIdxsTy (idxsTy, idxs) new = do
  let newAbs = abstractFreeVarsNoAnn idxs new
  Abs bs (Abs b UnitE) <- liftBuilder $ buildNaryAbs idxsTy \idxs' -> do
    ty' <- applyNaryAbs (sink newAbs) idxs'
    singletonBinderNest noHint ty'
  return $ Abs (bs >>> b) UnitE

type Idxs n = [SAtomName n]
type IdxNest = Nest (IxBinder SimpToImpIR)
type DestIdxs n = (EmptyAbs IdxNest n, Idxs n)
type DepVars n = [SAtomName n]

-- TODO: make `DestIdxs` a proper E-kinded thing
sinkDestIdxs :: DExt n l => DestIdxs n -> DestIdxs l
sinkDestIdxs (idxsTy, idxs) = (sink idxsTy, map sink idxs)

-- dest for the args and the result
-- TODO: de-dup some of the plumbing stuff here with the ordinary makeDest path
type NaryLamDest = Abs (Nest (BinderP AtomNameC Dest)) Dest

makeNaryLamDest :: NaryPiType SimpToImpIR n -> AllocType -> SubstImpM i n (AbsPtrs NaryLamDest n)
makeNaryLamDest piTy mgmt = do
  let allocInfo = (LLVM, CPU, mgmt) -- TODO! This is just a placeholder
  liftDestM allocInfo $ buildLocalDest do
    Abs decls dest <- buildDeclsDest $
                        makeNaryLamDestRec (Abs Empty UnitE, []) [] (sink piTy)
    case decls of
      Empty -> return dest
      _ -> error "shouldn't have decls if we have empty indices"

makeNaryLamDestRec :: forall n. Emits n => DestIdxs n -> DepVars n
                   -> NaryPiType SimpToImpIR n -> DestM n (NaryLamDest n)
makeNaryLamDestRec idxs depVars (NaryPiType (NonEmptyNest b bs) effs resultTy) = do
  case effs of
    Pure -> return ()
    OneEffect IOEffect -> return ()
    _ -> error "effectful functions not implemented"
  let argTy = binderType b
  argDest <- makeDestRec idxs depVars argTy
  Abs (b':>_) (Abs bs' resultDest) <-
    buildDepDest idxs depVars (getNameHint b) argTy \idxs' depVars' v -> do
      case bs of
        Empty -> do
          resultTy' <- applySubst (b@>v) resultTy
          Abs Empty <$> makeDestRec idxs' depVars' resultTy'
        Nest b1 bsRest -> do
          restPiTy <- applySubst (b@>v) $ NaryPiType (NonEmptyNest b1 bsRest) Pure resultTy
          makeNaryLamDestRec idxs' depVars' restPiTy
  return $ Abs (Nest (b':>argDest) bs') resultDest

-- TODO: should we put DestIdxs/DepVars in the monad? And maybe it should also
-- be a substituting one.
buildDepDest
  :: (SinkableE e, SubstE Name e, HoistableE e, Emits n)
  => DestIdxs n -> DepVars n -> NameHint -> SIType n
  -> (forall l. (Emits l, DExt n l) => DestIdxs l -> DepVars l -> SAtomName l -> DestM l (e l))
  -> DestM n (Abs (Binder SimpToImpIR) e n)
buildDepDest idxs depVars hint ty cont =
  buildAbsHoistingDeclsDest hint ty \v -> do
    let depVars' = map sink depVars ++ [v]
    cont (sinkDestIdxs idxs) depVars' v

-- `makeDestRec` builds an array of dests. The curried index type, `EmptyAbs
-- IdxNest n`, determines a set of valid indices, `Idxs n`. At each valid value
-- of `Idxs n` we should have a distinct dest. The `depVars` are a list of
-- variables whose values we won't know until we actually store something. The
-- resulting `Dest n` may mention these variables, but the pointer allocation
-- sizes can't.
makeDestRec :: forall n. Emits n => DestIdxs n -> DepVars n -> SIType n -> DestM n (Dest n)
makeDestRec idxs depVars ty = confuseGHC >>= \_ -> case ty of
  TabTy (b:>iTy) bodyTy -> do
    if depVars `anyFreeIn` iTy
      then do
        AbsPtrs (Abs bs dest) ptrsInfo <- buildLocalDest $ makeSingleDest [] $ sink ty
        ptrs <- forM ptrsInfo \(DestPtrInfo ptrTy size) -> do
                  ptr <- makeBaseTypePtr idxs (PtrType ptrTy)
                  return $ BoxPtr ptr size
        return $ BoxedRef $ Abs (NonDepNest bs ptrs) dest
      else do
        Distinct <- getDistinct
        idxsTy <- extendIdxsTy idxs iTy
        Con <$> TabRef <$> buildTabLamDest noHint iTy \v -> do
          let newIdxVals = map sink (snd idxs) <> [v]
          bodyTy' <- applyAbs (sink $ Abs b bodyTy) v
          makeDestRec (sink idxsTy, newIdxVals) (map sink depVars) bodyTy'
  TypeCon _ defName params -> do
    def <- lookupDataDef defName
    dcs <- instantiateDataDef def params
    Con . ConRef . Newtype ty <$> rec (dataDefRep dcs)
  DepPairTy depPairTy@(DepPairType (lBinder:>lTy) rTy) -> do
    lDest <- rec lTy
    rDestAbs <- buildDepDest idxs depVars (getNameHint lBinder) lTy \idxs' depVars' v -> do
      rTy' <- applySubst (lBinder@>v) rTy
      makeDestRec idxs' depVars' rTy'
    return $ DepPairRef lDest rDestAbs depPairTy
  StaticRecordTy types -> Con . ConRef . Newtype ty <$> rec (ProdTy $ toList types)
  VariantTy (NoExt types) -> Con . ConRef . Newtype ty <$> recSumType (toList types)
  TC con -> case con of
    BaseType b -> do
      ptr <- makeBaseTypePtr idxs b
      return $ Con $ BaseTypeRef ptr
    SumType cases -> recSumType cases
    ProdType tys  -> (Con . ConRef) <$> (ProdCon <$> traverse rec tys)
    Nat -> do
      x <- rec IdxRepTy
      return $ Con $ ConRef $ Newtype NatTy x
    Fin n -> do
      x <- rec NatTy
      return $ Con $ ConRef $ Newtype (TC $ Fin n) x
    _ -> error $ "not implemented: " ++ pprint con
  _ -> error $ "not implemented: " ++ pprint ty
  where
    rec = makeDestRec idxs depVars

    recSumType cases = do
      tag <- rec TagRepTy
      contents <- forM cases rec
      return $ Con $ ConRef $ SumAsProd cases tag $ contents

makeBaseTypePtr :: Emits n => DestIdxs n -> BaseType -> DestM n (SIAtom n)
makeBaseTypePtr (idxsTy, idxs) ty = do
  offset <- liftEmitBuilder $ computeOffset idxsTy idxs
  numel <- liftBuilder $ buildBlock $ computeElemCount (sink idxsTy)
  allocInfo <- getAllocInfo
  let addrSpace = chooseAddrSpace allocInfo numel
  let ptrTy = (addrSpace, ty)
  ptr <- Var <$> introduceNewPtr (getNameHint @String "ptr") ptrTy numel
  ptrOffset ptr offset
{-# SCC makeBaseTypePtr #-}

copyAtom :: Emits n => Dest n -> SIAtom n -> SubstImpM i n ()
copyAtom topDest topSrc = copyRec topDest topSrc
  where
    copyRec :: Emits n => Dest n -> SIAtom n -> SubstImpM i n ()
    copyRec dest src = confuseGHC >>= \_ -> case (dest, src) of
      (BoxedRef (Abs (NonDepNest bs ptrsSizes) boxedDest), _) -> do
        -- TODO: load old ptr and free (recursively)
        ptrs <- forM ptrsSizes \(BoxPtr ptrPtr sizeBlock) -> do
          PtrTy (_, (PtrType ptrTy)) <- getType ptrPtr
          size <- dropSubst $ translateBlock Nothing sizeBlock
          ptr <- emitAlloc ptrTy =<< fromScalarAtom size
          ptrPtr' <- fromScalarAtom ptrPtr
          storeAnywhere ptrPtr' ptr
          toScalarAtom ptr
        dest' <- applySubst (bs @@> map SubstVal ptrs) boxedDest
        copyRec dest' src
      (DepPairRef lRef rRefAbs _, DepPair l r _) -> do
        copyAtom lRef l
        rRef <- applyAbs rRefAbs (SubstVal l)
        copyAtom rRef r
      (Con destRefCon, _) -> case (destRefCon, src) of
        (TabRef _, TabLam _) -> zipTabDestAtom copyRec dest src
        (BaseTypeRef ptr, _) -> do
          ptr' <- fromScalarAtom ptr
          src' <- fromScalarAtom src
          storeAnywhere ptr' src'
        (ConRef (SumAsProd _ tag payload), _) -> case src of
          Con (SumAsProd _ tagSrc payloadSrc) -> do
            copyRec tag tagSrc
            unless (all (\case UnitVal -> True; _ -> False) payload) do -- optimization
              tagSrc' <- fromScalarAtom tagSrc
              emitSwitch tagSrc' (zip payload payloadSrc)
                \(d, s) -> copyRec (sink d) (sink s)
          SumVal _ con x -> do
            copyRec tag $ TagRepVal $ fromIntegral con
            copyRec (payload !! con) x
          _ -> error "unexpected src/dest pair"
        (ConRef destCon, Con srcCon) -> case (destCon, srcCon) of
          (ProdCon ds, ProdCon ss) -> zipWithM_ copyRec ds ss
          (Newtype _ eRef, Newtype _ e) -> copyRec eRef e
          _ -> error $ "Unexpected ref/val " ++ pprint (destCon, srcCon)
        _ -> error $ unlines $ ["unexpected src/dest pair:", pprint dest, "and", pprint src]
      _ -> error "unexpected src/dest pair"

    zipTabDestAtom :: Emits n
                   => (forall l. (Emits l, DExt n l) => Dest l -> SIAtom l -> SubstImpM i l ())
                   -> Dest n -> SIAtom n -> SubstImpM i n ()
    zipTabDestAtom f dest src = do
      Con (TabRef (TabLam (TabLamExpr b _))) <- return dest
      TabLam (TabLamExpr b' _)               <- return src
      checkAlphaEq (binderType b) (binderType b')
      let idxTy = binderAnn b
      n <- indexSetSizeImp idxTy
      emitLoop noHint Fwd n \i -> do
        idx <- unsafeFromOrdinalImp (sink idxTy) i
        destIndexed <- destGet (sink dest) idx
        srcIndexed  <- dropSubst $ translateExpr Nothing (TabApp (sink src) (idx:|[]))
        f destIndexed srcIndexed
{-# SCC copyAtom #-}

loadAnywhere :: Emits n => IExpr n -> SubstImpM i n (IExpr n)
loadAnywhere ptr = load ptr -- TODO: generalize to GPU backend

storeAnywhere :: Emits n => IExpr n -> IExpr n -> SubstImpM i n ()
storeAnywhere ptr val = store ptr val

store :: Emits n => IExpr n -> IExpr n -> SubstImpM i n ()
store dest src = emitStatement $ Store dest src

alloc :: Emits n => SIType n -> SubstImpM i n (Dest n)
alloc ty = makeAllocDest Managed ty

indexDest :: Emits n => Dest n -> SIAtom n -> SBuilderM n (Dest n)
indexDest (Con (TabRef (TabVal b body))) i = do
  body' <- applyAbs (Abs b body) $ SubstVal i
  emitBlock body'
indexDest dest _ = error $ pprint dest

loadDest :: Emits n => Dest n -> SBuilderM n (SIAtom n)
loadDest (DepPairRef lr rra a) = do
  l <- loadDest lr
  r <- loadDest =<< applyAbs rra (SubstVal l)
  return $ DepPair l r a
loadDest (BoxedRef (Abs (NonDepNest bs ptrsSizes) boxedDest)) = do
  ptrs <- forM ptrsSizes \(BoxPtr ptrPtr _) -> unsafePtrLoad ptrPtr
  dest <- applySubst (bs @@> map SubstVal ptrs) boxedDest
  loadDest dest
loadDest (Con dest) = do
 case dest of
   BaseTypeRef ptr -> unsafePtrLoad ptr
   TabRef (TabLam (TabLamExpr b body)) ->
     liftEmitBuilder $ buildTabLam (getNameHint b) (binderAnn b) \i -> do
       body' <- applySubst (b@>i) body
       result <- emitBlock body'
       loadDest result
   ConRef con -> Con <$> case con of
     ProdCon ds -> ProdCon <$> traverse loadDest ds
     -- FIXME: This seems dangerous! We should only load the dest chosen by the tag
     -- I think it might be ok given the current definition of loadDest, but I'm not
     -- 100% sure...
     SumAsProd ty tag xss -> SumAsProd ty <$> loadDest tag <*> mapM loadDest xss
     Newtype ty eRef -> Newtype ty <$> loadDest eRef
     _        -> error $ "Not a valid dest: " ++ pprint dest
   _ -> error $ "not implemented" ++ pprint dest
loadDest dest = error $ "not implemented" ++ pprint dest

-- TODO: Consider targeting LLVM's `switch` instead of chained conditionals.
emitSwitch :: forall i n a.  Emits n
           => IExpr n
           -> [a]
           -> (forall l. (Emits l, DExt n l) => a -> SubstImpM i l ())
           -> SubstImpM i n ()
emitSwitch testIdx args cont = do
  Distinct <- getDistinct
  rec 0 args
  where
    rec :: forall l. (Emits l, DExt n l) => Int -> [a] -> SubstImpM i l ()
    rec _ [] = error "Shouldn't have an empty list of alternatives"
    rec _ [arg] = cont arg
    rec curIdx (arg:rest) = do
      curTag     <- fromScalarAtom $ TagRepVal $ fromIntegral curIdx
      cond       <- emitInstr $ IPrimOp $ BinOp (ICmp Equal) (sink testIdx) curTag
      thisCase   <- buildBlockImp $ cont arg >> return []
      otherCases <- buildBlockImp $ rec (curIdx + 1) rest >> return []
      emitStatement $ ICond cond thisCase otherCases

emitLoop :: Emits n
         => NameHint -> Direction -> IExpr n
         -> (forall l. (DExt n l, Emits l) => IExpr l -> SubstImpM i l ())
         -> SubstImpM i n ()
emitLoop hint d n cont = do
  loopBody <- do
    withFreshIBinder hint (getIType n) \b@(IBinder _ ty)  -> do
      let i = IVar (binderName b) ty
      body <- buildBlockImp do
                cont =<< sinkM i
                return []
      return $ Abs b body
  emitStatement $ IFor d n loopBody

restructureScalarOrPairType :: SIType n -> [IExpr n] -> SubstImpM i n (SIAtom n)
restructureScalarOrPairType topTy topXs =
  go topTy topXs >>= \case
    (atom, []) -> return atom
    _ -> error "Wrong number of scalars"
  where
    go (PairTy t1 t2) xs = do
      (atom1, rest1) <- go t1 xs
      (atom2, rest2) <- go t2 rest1
      return (PairVal atom1 atom2, rest2)
    go (BaseTy _) (x:xs) = do
      x' <- toScalarAtom x
      return (x', xs)
    go ty _ = error $ "Not a scalar or pair: " ++ pprint ty

buildBlockImp
  :: (forall l. (Emits l, DExt n l) => SubstImpM i l [IExpr l])
  -> SubstImpM i n (ImpBlock n)
buildBlockImp cont = do
  Abs decls (ListE results) <- buildScopedImp $ ListE <$> cont
  return $ ImpBlock decls results

destToAtom :: Emits n => Dest n -> SubstImpM i n (SIAtom n)
destToAtom dest = liftBuilderImp $ loadDest =<< sinkM dest

destGet :: Emits n => Dest n -> SIAtom n -> SubstImpM i n (Dest n)
destGet dest i = liftBuilderImp $ do
  Distinct <- getDistinct
  indexDest (sink dest) (sink i)

destPairUnpack :: Dest n -> (Dest n, Dest n)
destPairUnpack (Con (ConRef (ProdCon [l, r]))) = (l, r)
destPairUnpack d = error $ "Not a pair destination: " ++ show d

_fromDestConsList :: Dest n -> [Dest n]
_fromDestConsList dest = case dest of
  Con (ConRef (ProdCon [h, t])) -> h : _fromDestConsList t
  Con (ConRef (ProdCon []))     -> []
  _ -> error $ "Not a dest cons list: " ++ pprint dest

makeAllocDest :: Emits n => AllocType -> SIType n -> SubstImpM i n (Dest n)
makeAllocDest allocTy ty = fst <$> makeAllocDestWithPtrs allocTy ty

backend_TODO_DONT_HARDCODE :: Backend
backend_TODO_DONT_HARDCODE = LLVM

curDev_TODO_DONT_HARDCODE :: Device
curDev_TODO_DONT_HARDCODE = CPU

makeAllocDestWithPtrs :: Emits n
                      => AllocType -> SIType n -> SubstImpM i n (Dest n, [IExpr n])
makeAllocDestWithPtrs allocTy ty = do
  let backend = backend_TODO_DONT_HARDCODE
  let curDev  = curDev_TODO_DONT_HARDCODE
  AbsPtrs absDest ptrDefs <- makeDest (backend, curDev, allocTy) ty
  ptrs <- forM ptrDefs \(DestPtrInfo ptrTy sizeBlock) -> do
    Distinct <- getDistinct
    size <- dropSubst $ translateBlock Nothing sizeBlock
    ptr <- emitAlloc ptrTy =<< fromScalarAtom size
    case ptrTy of
      (Heap _, _) | allocTy == Managed -> extendAllocsToFree ptr
      _ -> return ()
    return ptr
  ptrAtoms <- mapM toScalarAtom ptrs
  dest' <- applyNaryAbs absDest $ map SubstVal ptrAtoms
  return (dest', ptrs)

_copyDest :: Emits n => Maybe (Dest n) -> SIAtom n -> SubstImpM i n (SIAtom n)
_copyDest maybeDest atom = case maybeDest of
  Nothing   -> return atom
  Just dest -> copyAtom dest atom >> return atom

allocDest :: Emits n => Maybe (Dest n) -> SIType n -> SubstImpM i n (Dest n)
allocDest maybeDest t = case maybeDest of
  Nothing   -> alloc t
  Just dest -> return dest

type AllocInfo = (Backend, Device, AllocType)

data AllocType = Managed | Unmanaged  deriving (Show, Eq)

chooseAddrSpace :: AllocInfo -> SIBlock n -> AddressSpace
chooseAddrSpace (backend, curDev, allocTy) numel = case allocTy of
  Unmanaged -> Heap mainDev
  Managed | curDev == mainDev -> if isSmall then Stack else Heap mainDev
          | otherwise -> Heap mainDev
  where
    mainDev = case backend of
      LLVM        -> CPU
      LLVMMC      -> CPU
      LLVMCUDA    -> GPU
      MLIR        -> error "Shouldn't be compiling to Imp with MLIR backend"
      Interpreter -> error "Shouldn't be compiling to Imp with interpreter backend"

    isSmall :: Bool
    isSmall = case numel of
      Block _ Empty (Con (Lit l)) | getIntLit l <= 256 -> True
      _ -> False
{-# NOINLINE chooseAddrSpace #-}

-- === Determining buffer sizes and offsets using polynomials ===

type SBuilderM = BuilderM SimpToImpIR
type IndexStructure = EmptyAbs IdxNest :: E

computeElemCount :: Emits n => IndexStructure n -> SBuilderM n (SIAtom n)
computeElemCount (EmptyAbs Empty) =
  -- XXX: this optimization is important because we don't want to emit any decls
  -- in the case that we don't have any indices. The more general path will
  -- still compute `1`, but it might emit decls along the way.
  return $ IdxRepVal 1
computeElemCount idxNest' = do
  let (idxList, idxNest) = indexStructureSplit idxNest'
  sizes <- forM idxList indexSetSize
  listSize <- foldM imul (IdxRepVal 1) sizes
  nestSize <- elemCountPoly idxNest
  imul listSize nestSize

elemCountPoly :: Emits n => IndexStructure n -> SBuilderM n (SIAtom n)
elemCountPoly (Abs bs UnitE) = case bs of
  Empty -> return $ IdxRepVal 1
  Nest b@(_:>ixTy) rest -> do
   curSize <- indexSetSize ixTy
   restSizes <- computeSizeGivenOrdinal b $ EmptyAbs rest
   sumUsingPolysImp curSize restSizes

computeSizeGivenOrdinal
  :: EnvReader m
  => IxBinder SimpToImpIR n l -> IndexStructure l -> m n (Abs (Binder SimpToImpIR) SIBlock n)
computeSizeGivenOrdinal (b:>idxTy) idxStruct = liftBuilder do
  withFreshBinder noHint IdxRepTy \bOrdinal ->
    Abs (bOrdinal:>IdxRepTy) <$> buildBlock do
      i <- unsafeFromOrdinal (sink idxTy) $ Var $ sink $ binderName bOrdinal
      idxStruct' <- applySubst (b@>SubstVal i) idxStruct
      elemCountPoly $ sink idxStruct'

-- Split the index structure into a prefix of non-dependent index types
-- and a trailing nest of indices that can contain inter-dependencies.
indexStructureSplit :: IndexStructure n -> ([IxType SimpToImpIR n], IndexStructure n)
indexStructureSplit (Abs Empty UnitE) = ([], EmptyAbs Empty)
indexStructureSplit s@(Abs (Nest b rest) UnitE) =
  case hoist b (EmptyAbs rest) of
    HoistFailure _     -> ([], s)
    HoistSuccess rest' -> (binderAnn b:ans1, ans2)
      where (ans1, ans2) = indexStructureSplit rest'

getIxType :: EnvReader m => SAtomName n -> m n (IxType SimpToImpIR n)
getIxType name = do
  lookupAtomName name >>= \case
    IxBound ixTy -> return ixTy
    _ -> error $ "not an ix-bound name" ++ pprint name

computeOffset :: forall n. Emits n
              => IndexStructure n -> [SAtomName n] -> SBuilderM n (SIAtom n)
computeOffset idxNest' idxs = do
  let (idxList , idxNest ) = indexStructureSplit idxNest'
  let (listIdxs, nestIdxs) = splitAt (length idxList) idxs
  nestOffset   <- rec idxNest nestIdxs
  nestSize     <- computeElemCount idxNest
  listOrds     <- forM listIdxs \i -> do
    i' <- sinkM i
    ixTy <- getIxType i'
    ordinal ixTy (Var i')
  -- We don't compute the first size (which we don't need!) to avoid emitting unnecessary decls.
  idxListSizes <- case idxList of
    [] -> return []
    _  -> (IdxRepVal 0:) <$> forM (tail idxList) indexSetSize
  listOffset   <- fst <$> foldM accumStrided (IdxRepVal 0, nestSize) (reverse $ zip idxListSizes listOrds)
  iadd listOffset nestOffset
  where
   accumStrided (total, stride) (size, i) = (,) <$> (iadd total =<< imul i stride) <*> imul stride size
   -- Recursively process the dependent part of the nest
   rec :: IndexStructure n -> [SAtomName n] -> SBuilderM n (SIAtom n)
   rec (Abs Empty UnitE) [] = return $ IdxRepVal 0
   rec (Abs (Nest b@(_:>ixTy) bs) UnitE) (i:is) = do
     let rest = EmptyAbs bs
     rhsElemCounts <- computeSizeGivenOrdinal b rest
     iOrd <- ordinal ixTy $ Var i
     significantOffset <- sumUsingPolysImp iOrd rhsElemCounts
     remainingIdxStructure <- applySubst (b@>i) rest
     otherOffsets <- rec remainingIdxStructure is
     iadd significantOffset otherOffsets
   rec _ _ = error "zip error"

sumUsingPolysImp :: Emits n => SIAtom n -> Abs (Binder SimpToImpIR) SIBlock n -> SBuilderM n (SIAtom n)
sumUsingPolysImp lim (Abs i body) = do
  ab <- hoistDecls i body
  PairE lim' ab' <- emitImpVars (PairE lim ab) -- Algebra only works with Atom vars
  sumUsingPolys lim' ab'

emitImpVars ::
  (Emits n, HoistableE e, SubstE (SubstVal ImpNameC SIAtom) e, SinkableE e, SubstE Name e)
  => e n -> SBuilderM n (e n)
emitImpVars e = do
  let impVars = nameSetToList @ImpNameC (freeVarsE e)
  Abs impBs e' <- return $ abstractFreeVarsNoAnn impVars e
  substVals <- forM impVars \v -> do
    ty <- impVarType v
    atomVar <- emitAtomToName (getNameHint v) (AtomicIVar (LeftE v) ty)
    return $ (SubstVal (Var atomVar) :: SubstVal ImpNameC SIAtom ImpNameC _)
  applySubst (impBs @@> substVals) e'

hoistDecls
  :: ( Builder SimpToImpIR m, EnvReader m, Emits n
     , BindsNames b, BindsEnv b, SubstB Name b, SinkableB b)
  => b n l -> SIBlock l -> m n (Abs b SIBlock n)
hoistDecls b block = do
  Abs hoistedDecls rest <- liftEnvReaderM $
    refreshAbs (Abs b block) \b' (Block _ decls result) ->
      hoistDeclsRec b' Empty decls result
  ab <- emitDecls hoistedDecls rest
  refreshAbs ab \b'' blockAbs' ->
    Abs b'' <$> absToBlockInferringTypes blockAbs'

hoistDeclsRec
  :: (BindsNames b, SinkableB b)
  => b n1 n2 -> SIDecls n2 n3 -> SIDecls n3 n4 -> SIAtom n4
  -> EnvReaderM n3 (Abs SIDecls (Abs b (Abs SIDecls SIAtom)) n1)
hoistDeclsRec b declsAbove Empty result =
  return $ Abs Empty $ Abs b $ Abs declsAbove result
hoistDeclsRec b declsAbove (Nest decl declsBelow) result  = do
  let (Let _ expr) = decl
  exprIsPure <- isPure expr
  refreshAbs (Abs decl (Abs declsBelow result))
    \decl' (Abs declsBelow' result') ->
      case exchangeBs (PairB (PairB b declsAbove) decl') of
        HoistSuccess (PairB hoistedDecl (PairB b' declsAbove')) | exprIsPure -> do
          Abs hoistedDecls fullResult <- hoistDeclsRec b' declsAbove' declsBelow' result'
          return $ Abs (Nest hoistedDecl hoistedDecls) fullResult
        _ -> hoistDeclsRec b (declsAbove >>> Nest decl' Empty) declsBelow' result'

-- === Imp IR builder ===

data ImpInstrResult (n::S) = NoResults | OneResult !(IExpr n) | MultiResult !([IExpr n])

class (EnvReader m, EnvExtender m, Fallible1 m) => ImpBuilder (m::MonadKind1) where
  emitMultiReturnInstr :: Emits n => ImpInstr n -> m n (ImpInstrResult n)
  buildScopedImp
    :: SinkableE e
    => (forall l. (Emits l, DExt n l) => m l (e l))
    -> m n (Abs (Nest ImpDecl) e n)
  extendAllocsToFree :: Mut n => IExpr n -> m n ()

type ImpBuilder2 (m::MonadKind2) = forall i. ImpBuilder (m i)

withFreshIBinder
  :: ImpBuilder m
  => NameHint -> IType
  -> (forall l. DExt n l => IBinder n l -> m l a)
  -> m n a
withFreshIBinder hint ty cont = do
  withFreshBinder hint (ImpNameBinding ty) \b ->
    cont $ IBinder b ty
{-# INLINE withFreshIBinder #-}

emitCall :: Emits n
         => NaryPiType SimpToImpIR n -> ImpFunName n -> [SIAtom n] -> SubstImpM i n (SIAtom n)
emitCall piTy f xs = do
  AbsPtrs absDest ptrDefs <- makeNaryLamDest piTy Managed
  ptrs <- forM ptrDefs \(DestPtrInfo ptrTy sizeBlock) -> do
    Distinct <- getDistinct
    size <- dropSubst $ translateBlock Nothing sizeBlock
    emitAlloc ptrTy =<< fromScalarAtom size
  ptrAtoms <- mapM toScalarAtom ptrs
  dest <- applyNaryAbs absDest $ map SubstVal ptrAtoms
  resultDest <- storeArgDests dest xs
  _ <- impCall f ptrs
  destToAtom resultDest

buildImpFunction
  :: CallingConvention
  -> [(NameHint, IType)]
  -> (forall l. (Emits l, DExt n l) => [(ImpName l, BaseType)] -> SubstImpM i l [IExpr l])
  -> SubstImpM i n (ImpFunction n)
buildImpFunction cc argHintsTys body = do
  Abs bs (Abs decls (ListE results)) <-
    buildImpNaryAbs argHintsTys \vs -> ListE <$> body vs
  let resultTys = map getIType results
  let impFun = IFunType cc (map snd argHintsTys) resultTys
  return $ ImpFunction impFun $ Abs bs $ ImpBlock decls results

buildImpNaryAbs
  :: (SinkableE e, HasNamesE e, SubstE Name e, HoistableE e)
  => [(NameHint, IType)]
  -> (forall l. (Emits l, DExt n l) => [(Name ImpNameC l, BaseType)] -> SubstImpM i l (e l))
  -> SubstImpM i n (Abs (Nest IBinder) (Abs (Nest ImpDecl) e) n)
buildImpNaryAbs [] cont = do
  Distinct <- getDistinct
  Abs Empty <$> buildScopedImp (cont [])
buildImpNaryAbs ((hint,ty) : rest) cont = do
  withFreshIBinder hint ty \b -> do
    ab <- buildImpNaryAbs rest \vs -> do
      v <- sinkM $ binderName b
      cont ((v,ty) : vs)
    Abs bs body <- return ab
    return $ Abs (Nest b bs) body

emitInstr :: (ImpBuilder m, Emits n) => ImpInstr n -> m n (IExpr n)
emitInstr instr = do
  xs <- emitMultiReturnInstr instr
  case xs of
    OneResult x -> return x
    _   -> error "unexpected numer of return values"
{-# INLINE emitInstr #-}

emitStatement :: (ImpBuilder m, Emits n) => ImpInstr n -> m n ()
emitStatement instr = do
  xs <- emitMultiReturnInstr instr
  case xs of
    NoResults -> return ()
    _         -> error "unexpected numer of return values"
{-# INLINE emitStatement #-}

impCall :: (ImpBuilder m, Emits n) => ImpFunName n -> [IExpr n] -> m n [IExpr n]
impCall f args = emitMultiReturnInstr (ICall f args) <&> \case
  NoResults      -> []
  OneResult x    -> [x]
  MultiResult xs -> xs

emitAlloc :: (ImpBuilder m, Emits n) => PtrType -> IExpr n -> m n (IExpr n)
emitAlloc (addr, ty) n = emitInstr $ Alloc addr ty n
{-# INLINE emitAlloc #-}

impOffset :: Emits n => IExpr n -> IExpr n -> SubstImpM i n (IExpr n)
impOffset ref off = emitInstr $ IPrimOp $ PtrOffset ref off

cast :: Emits n => IExpr n -> BaseType -> SubstImpM i n (IExpr n)
cast x bt = emitInstr $ ICastOp bt x

load :: Emits n => IExpr n -> SubstImpM i n (IExpr n)
load x = emitInstr $ IPrimOp $ PtrLoad x

-- === Atom <-> IExpr conversions ===

fromScalarAtom :: SIAtom n -> SubstImpM i n (IExpr n)
fromScalarAtom atom = confuseGHC >>= \_ -> case atom of
  AtomicIVar (LeftE  v) t               -> return $ IVar    v t
  AtomicIVar (RightE v) (PtrType ptrTy) -> return $ IPtrVar v ptrTy
  Con (Lit x) -> return $ ILit x
  Var v -> lookupAtomName v >>= \case
    PtrLitBound ptrTy ptrName -> return $ IPtrVar ptrName ptrTy
    -- TODO: just store pointer names in Atom directly and avoid this
    _ -> error "The only atom names left should refer to pointer literals"
  _ -> error $ "Expected scalar, got: " ++ pprint atom

toScalarAtom :: Monad m => IExpr n -> m (SIAtom n)
toScalarAtom ie = case ie of
  ILit l   -> return $ Con $ Lit l
  IVar    v t     -> return $ AtomicIVar (LeftE  v) t
  IPtrVar v ptrTy -> return $ AtomicIVar (RightE v) (PtrType ptrTy)

-- TODO: we shouldn't need the rank-2 type here because ImpBuilder and Builder
-- are part of the same conspiracy.
liftBuilderImp :: (Emits n, SubstE (AtomSubstVal SimpToImpIR) e, SinkableE e)
               => (forall l. (Emits l, DExt n l) => BuilderM SimpToImpIR l (e l))
               -> SubstImpM i n (e n)
liftBuilderImp cont = do
  Abs decls result <- liftBuilder $ buildScoped cont
  dropSubst $ translateDeclNest decls $ substM result
{-# INLINE liftBuilderImp #-}

-- === Type classes ===

unsafeFromOrdinalImp :: Emits n => IxType SimpToImpIR n -> IExpr n -> SubstImpM i n (SIAtom n)
unsafeFromOrdinalImp (IxType _ dict) i = do
  i' <- (Con . Newtype NatTy) <$> toScalarAtom i
  case dict of
    DictCon (IxFin n) -> return $ Con $ Newtype (TC $ Fin n) i'
    DictCon (ExplicitMethods d params) -> do
      SpecializedDictBinding (SpecializedDict _ (Just fs)) <- lookupEnv d
      appSpecializedIxMethod (fs !! fromEnum UnsafeFromOrdinal) (params ++ [i'])
    _ -> error $ "Not a simplified dict: " ++ pprint dict

indexSetSizeImp :: Emits n => IxType SimpToImpIR n -> SubstImpM i n (IExpr n)
indexSetSizeImp (IxType _ dict) = do
  ans <- case dict of
    DictCon (IxFin n) -> return n
    DictCon (ExplicitMethods d params) -> do
      SpecializedDictBinding (SpecializedDict _ (Just fs)) <- lookupEnv d
      appSpecializedIxMethod (fs !! fromEnum Size) (params ++ [UnitVal])
    _ -> error $ "Not a simplified dict: " ++ pprint dict
  fromScalarAtom $ unwrapBaseNewtype ans

appSpecializedIxMethod :: Emits n => NaryLamExpr SimpIR n -> [SIAtom n] -> SubstImpM i n (SIAtom n)
appSpecializedIxMethod simpLam args = do
  NaryLamExpr bs _ body <- return $ injectIRE simpLam
  dropSubst $ extendSubst (bs @@> map SubstVal args) $ translateBlock Nothing body

-- === Abstracting link-time objects ===

abstractLinktimeObjects
  :: forall m n. EnvReader m
  => ImpFunction n -> m n (ClosedImpFunction n, [ImpFunName n], [PtrName n])
abstractLinktimeObjects f = do
  let allVars = freeVarsE f
  (funVars, funTys) <- unzip <$> forMFilter (nameSetToList @ImpFunNameC allVars) \v ->
    lookupImpFun v <&> \case
      ImpFunction ty _ -> Just (v, ty)
      FFIFunction _ _ -> Nothing
  (ptrVars, ptrTys) <- unzip <$> forMFilter (nameSetToList @PtrNameC allVars) \v -> do
    (ty, _) <- lookupPtrName v
    return $ Just (v, ty)
  Abs funBs (Abs ptrBs f') <- return $ abstractFreeVarsNoAnn funVars $
                                       abstractFreeVarsNoAnn ptrVars f
  let funBs' =  zipWithNest funBs funTys \b ty -> IFunBinder b ty
  let ptrBs' =  zipWithNest ptrBs ptrTys \b ty -> PtrBinder  b ty
  return (ClosedImpFunction funBs' ptrBs' f', funVars, ptrVars)

-- === type checking imp programs ===

toIVectorType :: SIType n -> IVectorType
toIVectorType = \case
  BaseTy vty@(Vector _ _) -> vty
  _ -> error "Not a vector type"

impFunType :: ImpFunction n -> IFunType
impFunType (ImpFunction ty _) = ty
impFunType (FFIFunction ty _) = ty

getIType :: IExpr n -> IType
getIType (ILit l) = litType l
getIType (IVar _ ty) = ty
getIType (IPtrVar _ ty) = PtrType ty

impInstrTypes :: EnvReader m => ImpInstr n -> m n [IType]
impInstrTypes instr = case instr of
  IPrimOp op      -> return [impOpType op]
  ICastOp t _     -> return [t]
  IBitcastOp t _  -> return [t]
  Alloc a ty _    -> return [PtrType (a, ty)]
  Store _ _       -> return []
  Free _          -> return []
  IThrowError     -> return []
  MemCopy _ _ _   -> return []
  IFor _ _ _      -> return []
  IWhile _        -> return []
  ICond _ _ _     -> return []
  ILaunch _ _ _   -> return []
  ISyncWorkgroup  -> return []
  IVectorBroadcast _ vty -> return [vty]
  IVectorIota vty        -> return [vty]
  IQueryParallelism _ _ -> return [IIdxRepTy, IIdxRepTy]
  ICall f _ -> do
    IFunType _ _ resultTys <- impFunType <$> lookupImpFun f
    return resultTys

-- TODO: reuse type rules in Type.hs
impOpType :: IPrimOp n -> IType
impOpType pop = case pop of
  BinOp op x _       -> typeBinOp op (getIType x)
  UnOp  op x         -> typeUnOp  op (getIType x)
  Select  _ x  _     -> getIType x
  PtrLoad ref        -> ty  where PtrType (_, ty) = getIType ref
  PtrOffset ref _    -> PtrType (addr, ty)  where PtrType (addr, ty) = getIType ref
  OutputStream       -> hostPtrTy $ Scalar Word8Type
    where hostPtrTy ty = PtrType (Heap CPU, ty)
  _ -> unreachable
  where unreachable = error $ "Not allowed in Imp IR: " ++ show pop

instance CheckableE ImpFunction where
  checkE = substM -- TODO!

-- TODO: Don't use Core Envs for Imp!
instance BindsEnv ImpDecl where
  toEnvFrag (ImpLet bs _) = toEnvFrag bs

instance BindsEnv IBinder where
  toEnvFrag (IBinder b ty) =  toEnvFrag $ b :> ImpNameBinding ty

instance SubstB (AtomSubstVal SimpToImpIR) IBinder

captureClosure
  :: HoistableB b
  => b n l -> SIAtom l -> ([ImpName l], NaryAbs ImpNameC SIAtom n)
captureClosure decls result = do
  let vs = capturedVars decls result
  let ab = abstractFreeVarsNoAnn vs result
  case hoist decls ab of
    HoistSuccess abHoisted -> (vs, abHoisted)
    HoistFailure _ ->
      error "shouldn't happen"  -- but it will if we have types that reference
                                -- local vars. We really need a telescope.

capturedVars :: (Color c, BindsNames b, HoistableE e)
             => b n l -> e l -> [Name c l]
capturedVars b e = nameSetToList nameSet
  where nameSet = R.intersection (toNameSet (toScopeFrag b)) (freeVarsE e)

-- See Note [Confuse GHC] from Simplify.hs
confuseGHC :: EnvReader m => m n (DistinctEvidence n)
confuseGHC = getDistinct
{-# INLINE confuseGHC #-}
