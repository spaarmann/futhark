-- | Code generation for ImpCode with WebGPU.
module Futhark.CodeGen.ImpGen.WebGPU
  ( compileProg,
    Warnings,
  )
where

import Control.Monad.State
import Data.Bifunctor (second)
import Data.Either (rights)
import Data.Map qualified as M
import Data.Set qualified as S
import Data.Text qualified as T
import Futhark.CodeGen.ImpCode.GPU qualified as ImpGPU
import Futhark.CodeGen.ImpCode.WebGPU
import Futhark.CodeGen.ImpGen.WGSL qualified as WGSL
import Futhark.CodeGen.ImpGen.GPU qualified as ImpGPU
import Futhark.IR.GPUMem qualified as F
import Futhark.MonadFreshNames
import Futhark.Util (convFloat, zEncodeText)
import Futhark.Util.Pretty (docText)
import Language.Futhark.Warnings (Warnings)

-- State carried during WebGPU translation.
data WebGPUS = WebGPUS
  { -- | Accumulated code.
    wsCode :: T.Text,
    wsSizes :: M.Map Name SizeClass
  }

-- The monad in which we perform the translation. The state will
-- probably need to be extended, and maybe we will add a Reader.
type WebGPUM = State WebGPUS

addSize :: Name -> SizeClass -> WebGPUM ()
addSize key sclass =
  modify $ \s -> s {wsSizes = M.insert key sclass $ wsSizes s}

addCode :: T.Text -> WebGPUM ()
addCode code =
  modify $ \s -> s {wsCode = wsCode s <> code}

entryParams :: [WGSL.Param]
entryParams =
  [ WGSL.Param "workgroup_id" (WGSL.Prim (WGSL.Vec3 WGSL.UInt32))
      [WGSL.Attrib "builtin" [WGSL.VarExp "workgroup_id"]],
    WGSL.Param "local_id" (WGSL.Prim (WGSL.Vec3 WGSL.UInt32))
      [WGSL.Attrib "builtin" [WGSL.VarExp "local_invocation_id"]]
  ]

builtinLockstepWidth, builtinBlockSize :: WGSL.Ident
builtinLockstepWidth = "_lockstep_width"
builtinBlockSize = "_block_size"

-- Main function for translating an ImpGPU kernel to a WebGPU kernel.
onKernel :: ImpGPU.Kernel -> WebGPUM HostOp
onKernel kernel = do
  addCode $ "Input for " <> name <> "\n"
  addCode $ prettyText kernel <> "\n\n"
  addCode $ "Code for " <> name <> ":\n"
  addCode "== SHADER START ==\n"

  let overrideDecls = genConstAndBuiltinDecls kernel
  addCode $ docText (WGSL.prettyDecls overrideDecls <> "\n\n")

  let (scalarDecls, copies) = genScalarCopies kernel
  addCode $ docText (WGSL.prettyDecls scalarDecls <> "\n\n")

  let memDecls = genMemoryDecls kernel
  addCode $ docText (WGSL.prettyDecls memDecls <> "\n\n")

  let wgslBody = WGSL.Seq copies $ genWGSLStm (ImpGPU.kernelBody kernel)
  let attribs = [WGSL.Attrib "compute" [],
                 WGSL.Attrib "workgroup_size" [WGSL.VarExp builtinBlockSize]]
  let wgslFun = WGSL.Function
                  { WGSL.funName = name,
                    WGSL.funAttribs = attribs,
                    WGSL.funParams = entryParams,
                    WGSL.funBody = wgslBody
                  }
  addCode $ prettyText wgslFun
  addCode "\n"

  addCode "== SHADER END ==\n"

  -- TODO: return something sensible.
  pure $ LaunchKernel SafetyNone (ImpGPU.kernelName kernel) 0 [] [] []
    where name = textToIdent $ nameToText (ImpGPU.kernelName kernel)

onHostOp :: ImpGPU.HostOp -> WebGPUM HostOp
onHostOp (ImpGPU.CallKernel k) = onKernel k
onHostOp (ImpGPU.GetSize v key size_class) = do
  addSize key size_class
  pure $ GetSize v key
onHostOp (ImpGPU.CmpSizeLe v key size_class x) = do
  addSize key size_class
  pure $ CmpSizeLe v key x
onHostOp (ImpGPU.GetSizeMax v size_class) =
  pure $ GetSizeMax v size_class

-- | Generate WebGPU host and device code.
kernelsToWebGPU :: ImpGPU.Program -> Program
kernelsToWebGPU prog =
  let ImpGPU.Definitions
        types
        (ImpGPU.Constants ps consts)
        (ImpGPU.Functions funs) = prog

      initial_state = WebGPUS {wsCode = mempty, wsSizes = mempty}

      ((consts', funs'), translation) =
        flip runState initial_state $
          (,) <$> traverse onHostOp consts <*> traverse (traverse (traverse onHostOp)) funs

      prog' =
        Definitions types (Constants ps consts') (Functions funs')

      webgpu_prelude = mempty
      constants = mempty
      kernels = mempty
      params = mempty
      failures = mempty
   in Program
        { webgpuProgram = wsCode translation,
          webgpuPrelude = webgpu_prelude,
          webgpuMacroDefs = constants,
          webgpuKernelNames = kernels,
          webgpuParams = params,
          webgpuFailures = failures,
          hostDefinitions = prog'
        }

-- | Compile the program to ImpCode with WebGPU kernels.
compileProg :: (MonadFreshNames m) => F.Prog F.GPUMem -> m (Warnings, Program)
compileProg prog = second kernelsToWebGPU <$> ImpGPU.compileProgOpenCL prog

primWGSLType :: PrimType -> WGSL.PrimType
primWGSLType (IntType Int32) = WGSL.Int32
-- TODO: WGSL only has 32-bit primitive integers
primWGSLType (IntType Int8) = WGSL.Int32
primWGSLType (IntType Int16) = WGSL.Int32
primWGSLType (IntType Int64) = WGSL.Int32
primWGSLType (FloatType Float16) = WGSL.Float16
primWGSLType (FloatType Float32) = WGSL.Float32
primWGSLType (FloatType Float64) = error "TODO: WGSL has no f64"
primWGSLType Bool = WGSL.Bool
-- TODO: Make sure we do not ever codegen statements involving Unit variables
primWGSLType Unit = error "TODO: no unit in WGSL"

genWGSLStm :: Code ImpGPU.KernelOp -> WGSL.Stmt
genWGSLStm Skip = WGSL.Skip
genWGSLStm (s1 :>>: s2) = WGSL.Seq (genWGSLStm s1) (genWGSLStm s2)
genWGSLStm (DeclareScalar name _ typ) =
  WGSL.DeclareVar (nameToIdent name) (WGSL.Prim $ primWGSLType typ)
genWGSLStm (If cond cThen cElse) = 
  WGSL.If (genWGSLExp $ untyped cond) (genWGSLStm cThen) (genWGSLStm cElse)
genWGSLStm (Write mem i _ _ _ v) =
  WGSL.AssignIndex (nameToIdent mem) (countExp i) (genWGSLExp v)
genWGSLStm (SetScalar name e) = WGSL.Assign (nameToIdent name) (genWGSLExp e)
genWGSLStm (Read tgt mem i _ _ _) =
  WGSL.Assign (nameToIdent tgt) (WGSL.IndexExp (nameToIdent mem) (countExp i))
genWGSLStm (Op (ImpGPU.GetBlockId dest i)) = 
  WGSL.Assign (nameToIdent dest) $
    WGSL.to_i32 (WGSL.IndexExp "workgroup_id" (WGSL.IntExp i))
genWGSLStm (Op (ImpGPU.GetLocalId dest i)) = 
  WGSL.Assign (nameToIdent dest) $
    WGSL.to_i32 (WGSL.IndexExp "local_id" (WGSL.IntExp i))
genWGSLStm (Op (ImpGPU.GetLocalSize dest _)) = 
  WGSL.Assign (nameToIdent dest) (WGSL.VarExp builtinBlockSize)
genWGSLStm (Op (ImpGPU.GetLockstepWidth dest)) = 
  WGSL.Assign (nameToIdent dest) (WGSL.VarExp builtinLockstepWidth)
genWGSLStm _ = WGSL.Skip

-- TODO: This does not respect the indicated sizes and signedness currently, so
-- we will always perform operations according to the declared types of the
-- involved variables.
wgslBinOp :: BinOp -> WGSL.BinOp
wgslBinOp (Add _ _) = "+"
wgslBinOp (FAdd _) = "+"
wgslBinOp (Sub _ _) = "-"
wgslBinOp (FSub _) = "-"
wgslBinOp (Mul _ _) = "*"
wgslBinOp (FMul _) = "*"
wgslBinOp _ = "???"

-- TODO: Similar to above, this does not respect signedness properly right now.
wgslCmpOp :: CmpOp -> WGSL.BinOp
wgslCmpOp (CmpEq _) = "=="
wgslCmpOp (CmpUlt _) = "<"
wgslCmpOp (CmpUle _) = "<="
wgslCmpOp (CmpSlt _) = "<"
wgslCmpOp (CmpSle _) = "<="
wgslCmpOp (FCmpLt _) = "<"
wgslCmpOp (FCmpLe _) = "<="
wgslCmpOp CmpLlt = "<" -- TODO: This does not actually work for bools.
wgslCmpOp CmpLle = "=="

valueFloat :: FloatValue -> Double
valueFloat (Float16Value v) = convFloat v
valueFloat (Float32Value v) = convFloat v
valueFloat (Float64Value v) = v

genWGSLExp :: Exp -> WGSL.Exp
genWGSLExp (LeafExp name _) = WGSL.VarExp $ nameToIdent name
genWGSLExp (ValueExp (IntValue v)) = WGSL.IntExp (valueIntegral v)
genWGSLExp (ValueExp (FloatValue v)) = WGSL.FloatExp (valueFloat v)
genWGSLExp (ValueExp (BoolValue v)) = WGSL.BoolExp v
genWGSLExp (ValueExp UnitValue) =
  error "should not attempt to generate unit expressions"
genWGSLExp (BinOpExp op e1 e2) =
  WGSL.BinOpExp (wgslBinOp op) (genWGSLExp e1) (genWGSLExp e2)
genWGSLExp (CmpOpExp op e1 e2) =
  WGSL.BinOpExp (wgslCmpOp op) (genWGSLExp e1) (genWGSLExp e2)
-- don't support different integer types currently
genWGSLExp (ConvOpExp (ZExt _ _) e) = genWGSLExp e
-- don't support different integer types currently
genWGSLExp (ConvOpExp (SExt _ _) e) = genWGSLExp e
genWGSLExp _ = WGSL.StringExp "<not implemented>"

countExp :: Count Elements (TExp Int64) -> WGSL.Exp
countExp = genWGSLExp . untyped . unCount

scalarUses :: [ImpGPU.KernelUse] -> [(WGSL.Ident, WGSL.Typ)]
scalarUses [] = []
scalarUses ((ImpGPU.ScalarUse name typ):us) =
  (nameToIdent name, WGSL.Prim (primWGSLType typ)) : scalarUses us
scalarUses (_:us) = scalarUses us

-- | Generate a struct declaration and corresponding uniform binding declaration
-- for all the scalar 'KernelUse's. Also generate a block of statements that
-- copies the struct fields into local variables so the kernel body can access
-- them unmodified.
genScalarCopies :: ImpGPU.Kernel -> ([WGSL.Declaration], WGSL.Stmt)
genScalarCopies kernel = ([structDecl, bufferDecl], copies)
  where
    structName = textToIdent $
      "Scalars_" <> nameToText (ImpGPU.kernelName kernel)
    bufferName = textToIdent $
      "scalars_" <> nameToText (ImpGPU.kernelName kernel)
    scalars = scalarUses (ImpGPU.kernelUses kernel)
    structDecl = WGSL.StructDecl $
      WGSL.Struct structName (map (uncurry WGSL.Field) scalars)
    bufferAttribs = WGSL.bindingAttribs 0 0
    bufferDecl =
      WGSL.VarDecl bufferAttribs WGSL.Uniform bufferName (WGSL.Named structName)
    copies = WGSL.stmts $ concatMap copy scalars 
    copy (name, typ) =
      [WGSL.DeclareVar name typ,
       WGSL.Assign name (WGSL.FieldExp bufferName name)]

-- | Internally, memory buffers are untyped but WGSL requires us to annotate the
-- binding with a type. Search the kernel body for any reads and writes to the
-- given buffer and return all types it is accessed at.
findMemoryTypes :: ImpGPU.Kernel -> VName -> [ImpGPU.PrimType]
findMemoryTypes kernel name = S.elems $ find (ImpGPU.kernelBody kernel)
  where
    find (ImpGPU.Write n _ t _ _ _) | n == name = S.singleton t
    find (ImpGPU.Read _ n _ t _ _) | n == name = S.singleton t
    find (s1 :>>: s2) = find s1 <> find s2
    find (For _ _ body) = find body
    find (While _ body) = find body
    find (If _ s1 s2) = find s1 <> find s2
    find _ = S.empty

genMemoryDecls :: ImpGPU.Kernel -> [WGSL.Declaration]
genMemoryDecls kernel = zipWith memDecl [1..] uses
  where
    uses = do
      ImpGPU.MemoryUse name <- ImpGPU.kernelUses kernel
      let types = findMemoryTypes kernel name
      case types of
        [] -> [] -- Do not need to generate declarations for unused buffers
        [t] -> pure (name, t)
        _more ->
          error "Using buffer at multiple type not supported in WebGPU backend"
    memDecl i (name, typ) =
      WGSL.VarDecl (WGSL.bindingAttribs 0 i) (WGSL.Storage WGSL.ReadWrite)
                   (nameToIdent name) (WGSL.Array $ primWGSLType typ)

-- | Find all named 'KernelConst's used in the kernel either as block size or as
-- part of a 'KernelConstExp' in a 'ConstUse'. We will generate `override`
-- declarations for all of them.
-- TODO: This does not handle 'SizeMaxConst' 'KernelConst's yet.
kernelConsts :: ImpGPU.Kernel -> S.Set (ImpGPU.KernelConst, PrimType)
kernelConsts kernel = S.union blockSizeConsts constUses
  where
    blockSizeConsts = S.fromList $
      map (, IntType Int32) (rights $ ImpGPU.kernelBlockSize kernel)
    constUseExps = [ e | ImpGPU.ConstUse _ e <- ImpGPU.kernelUses kernel] 
    constUses = foldl S.union S.empty $ map leafExpTypes constUseExps

-- | Generate `override` declarations for kernel 'ConstUse's and
-- backend-provided values (like block size and lockstep width).
genConstAndBuiltinDecls :: ImpGPU.Kernel -> [WGSL.Declaration]
genConstAndBuiltinDecls kernel = constDecls ++ builtinDecls
  where 
    constDecls =
      [ WGSL.OverrideDecl (nameToIdent name) (WGSL.Prim WGSL.Int32) |
        ImpGPU.ConstUse name _ <- ImpGPU.kernelUses kernel ]
    builtinDecls =
      [WGSL.OverrideDecl builtinLockstepWidth (WGSL.Prim WGSL.Int32),
       WGSL.OverrideDecl builtinBlockSize (WGSL.Prim WGSL.Int32)]

nameToIdent :: VName -> WGSL.Ident
nameToIdent = zEncodeText . prettyText

textToIdent :: T.Text -> WGSL.Ident
textToIdent = zEncodeText
