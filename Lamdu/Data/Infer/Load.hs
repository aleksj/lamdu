{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Data.Infer.Load
  ( Loader(..)
  , Error(..)
  , LoadedDef(..), ldDef, ldType
  , T, load, newDefinition
  , exprIntoContext
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens.Operators
import Control.Monad (when)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Either (EitherT(..))
import Control.Monad.Trans.State (StateT)
import Control.MonadA (MonadA)
import Data.Maybe.Utils (unsafeUnjust)
import Data.Monoid (Monoid(..))
import Data.Traversable (sequenceA)
import Lamdu.Data.Infer.Context (Context)
import Lamdu.Data.Infer.RefTags (ExprRef)
import Lamdu.Data.Infer.TypedValue (ScopedTypedValue(..), TypedValue(..), tvType, stvTV)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.Either as Either
import qualified Data.Map as Map
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Infer.Context as Context
import qualified Lamdu.Data.Infer.GuidAliases as GuidAliases
import qualified Lamdu.Data.Infer.RefData as RefData

data LoadedDef def = LoadedDef
  { _ldDef :: def
  , _ldType :: ExprRef def
  }
Lens.makeLenses ''LoadedDef

newtype Loader def m = Loader
  { loadDefType :: def -> m (Expr.Expression def ())
    -- TODO: For synonyms we'll need loadDefVal
  }

newtype Error def = LoadUntypedDef def
  deriving (Show)

type T def m = StateT (Context def) (EitherT (Error def) m)

exprIntoContext ::
  (Ord def, MonadA m) => RefData.Scope def -> Expr.Expression def () ->
  StateT (Context def) m (ExprRef def)
exprIntoContext scope (Expr.Expression body ()) = do
  newBody <-
    case body of
    Expr.BodyLam (Expr.Lam k paramGuid paramType result) -> do
      paramTypeRef <- exprIntoContext scope paramType
      paramIdRep <- Lens.zoom Context.guidAliases $ GuidAliases.getRep paramGuid
      Expr.BodyLam . Expr.Lam k paramGuid paramTypeRef <$>
        exprIntoContext (scope & RefData.scopeMap . Lens.at paramIdRep .~ Just paramTypeRef) result
    -- TODO: Assert parameterRefs are not out of scope here
    _ -> body & Lens.traverse %%~ exprIntoContext scope
  Context.fresh scope newBody

-- Error includes untyped def use
loadDefTypeIntoRef :: (Ord def, MonadA m) => Loader def m -> def -> T def m (ExprRef def)
loadDefTypeIntoRef (Loader loader) def = do
  loadedDefType <- lift . lift $ loader def
  when (Lens.has ExprLens.holePayloads loadedDefType) .
    lift . Either.left $ LoadUntypedDef def
  exprIntoContext (RefData.Scope mempty Nothing) loadedDefType

newDefinition :: (MonadA m, Ord def) => def -> StateT (Context def) m (ScopedTypedValue def)
newDefinition def = do
  stv <-
    (`ScopedTypedValue` scope)
    <$> (TypedValue <$> mkHole <*> mkHole)
  Context.defTVs . Lens.at def %= setRef (stv ^. stvTV)
  return stv
  where
    mkHole = Context.freshHole scope
    scope = RefData.emptyScope def
    setRef tv Nothing = Just tv
    setRef _ (Just _) = error "newDefinition overrides existing def type"

load ::
  (Ord def, MonadA m) =>
  Loader def m -> Expr.Expression def a ->
  T def m (Expr.Expression (LoadedDef def) a)
load loader expr = do
  existingDefTVs <- Lens.use Context.defTVs <&> Lens.mapped %~ return
  -- Left wins in union
  allDefTVs <- sequenceA $ existingDefTVs `Map.union` defLoaders
  Context.defTVs .= allDefTVs
  let
    getDefRef def =
      LoadedDef def .
      unsafeUnjust "We just added all defs!" $
      allDefTVs ^? Lens.ix def . tvType
  expr & ExprLens.exprDef %~ getDefRef & return
  where
    defLoaders =
      Map.fromList
      [  (def
        , TypedValue
          <$> Context.freshHole (RefData.Scope mempty (Just def))
          <*> loadDefTypeIntoRef loader def)
      | def <- expr ^.. ExprLens.exprDef
      ]
