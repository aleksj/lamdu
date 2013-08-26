{-# LANGUAGE DeriveFunctor, DeriveDataTypeable, TemplateHaskell #-}
module Lamdu.Data.Infer.ImplicitVariables
  ( add, Payload(..)
  ) where

import Control.Lens.Operators
import Control.Monad (void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT, execStateT, state)
import Data.Binary (Binary(..), getWord8, putWord8)
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Foldable (traverse_)
import Data.Store.Guid (Guid)
import Data.Typeable (Typeable)
import Lamdu.Data.Infer.Context (Context)
import Lamdu.Data.Infer.RefData (RefData)
import Lamdu.Data.Infer.TypedValue (ScopedTypedValue(..), TypedValue(..))
import System.Random (RandomGen, random)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Data.Store.Guid as Guid
import qualified Data.UnionFind.WithData as UFData
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Infer as Infer
import qualified Lamdu.Data.Infer.Context as Context
import qualified Lamdu.Data.Infer.LamWrap as LamWrap
import qualified Lamdu.Data.Infer.Load as Load
import qualified Lamdu.Data.Infer.Monad as InferM
import qualified Lamdu.Data.Infer.RefData as RefData
import qualified Lamdu.Data.Infer.TypedValue as TypedValue

data Payload a = Stored a | AutoGen Guid
  deriving (Eq, Ord, Show, Functor, Typeable)
derive makeBinary ''Payload

add ::
  (Show def, Ord def, RandomGen gen) =>
  gen -> def ->
  Expr.Expression (Load.LoadedDef def) (ScopedTypedValue def, a) ->
  StateT (Context def) (Either (InferM.Error def))
  (Expr.Expression (Load.LoadedDef def) (ScopedTypedValue def, Payload a))
add gen def expr =
  expr ^.. ExprLens.lambdaParamTypes . Lens.traverse . Lens._1
  & traverse_ (onEachParamTypeSubexpr def)
  & (`execStateT` gen)
  & (`execStateT` (expr <&> Lens._2 %~ Stored))

isUnrestrictedHole :: RefData ref -> Bool
isUnrestrictedHole refData =
  null (refData ^. RefData.rdRestrictions)
  && Lens.has (RefData.rdBody . ExprLens.bodyHole) refData

-- We try to fill each hole *value* of each subexpression of each
-- param *type* with type-vars. Since those are part of the "stored"
-- expr, they have a TV/inferred-type we can use to unify both val and
-- type.
onEachParamTypeSubexpr ::
  (Ord def, RandomGen gen) =>
  def -> ScopedTypedValue def ->
  StateT gen
  (StateT (Expr.Expression (Load.LoadedDef def) (ScopedTypedValue def, Payload a))
   (StateT (Context def)
    (Either (InferM.Error def)))) ()
onEachParamTypeSubexpr def stv = do
  -- TODO: can use a cached deref here
  iValData <-
    lift . lift . Lens.zoom Context.ufExprs . UFData.read $
    stv ^. TypedValue.stvTV . TypedValue.tvVal
  when (isUnrestrictedHole iValData) $ do
    paramId <- state random
    -- implicitValRef <= getVar paramId
    implicitValRef <-
      lift . lift . Load.exprIntoContext (stv ^. TypedValue.stvScope) $
      ExprLens.pureExpr . ExprLens.bodyParameterRef # paramId
    -- Make a new type ref for the implicit (we can't just re-use the
    -- given stv type ref because we need to intersect/restrict its
    -- scope)
    implicitTypeRef <-
      lift . lift $ Context.freshHole (RefData.emptyScope def)
    -- Wrap with (paramId:implicitTypeRef) lambda
    lift State.get
      >>= lift . lift . LamWrap.lambdaWrap paramId implicitTypeRef
      <&> Lens.mapped . Lens._2 %~ joinPayload . toPayload paramId
      >>= lift . State.put
    -- tv <- TV implicitValRef implicitTypeRef
    let
      implicit = TypedValue implicitValRef implicitTypeRef
      tv = stv ^. TypedValue.stvTV
    void . lift . lift $ Infer.unify tv implicit
  where
    toPayload paramId Nothing = AutoGen $ Guid.augment "implicitLam" paramId
    toPayload _ (Just x) = Stored x

joinPayload :: Payload (Payload a) -> Payload a
joinPayload (AutoGen guid) = AutoGen guid
joinPayload (Stored x) = x