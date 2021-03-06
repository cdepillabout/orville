{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
module Database.Orville.Internal.RelationalMap
  ( mkTableDefinition
  , TableParams(..)
  , RelationalMap
  , mapAttr, mapField, attrField
  , maybeMapper, prefixMap, partialMap, readOnlyMap
  ) where

import            Control.Monad (when, join)
import            Control.Monad.Reader (ask)
import            Control.Monad.State (modify)
import            Data.Convertible
import            Database.HDBC

import            Database.Orville.Internal.FieldDefinition
import            Database.Orville.Internal.FromSql
import            Database.Orville.Internal.Types

data TableParams entity = TableParams
  { tblName :: String
  , tblMapper :: RelationalMap (entity Record) (entity Record)
  , tblSafeToDelete :: [String]
  , tblSetKey :: forall key1 key2. key2 -> entity key1 -> entity key2
  , tblGetKey :: forall key. entity key -> key
  , tblComments :: TableComments ()
  }

mkTableDefinition :: TableParams entity -> TableDefinition entity
mkTableDefinition p@(TableParams {..}) = TableDefinition
  { tableFields  = fields tblMapper
  , tableFromSql = mkFromSql tblMapper
  , tableToSql   = getComponent (unsafeSquashPrimaryKey p) (mkToSql tblMapper)

  , tableName = tblName
  , tableSafeToDelete = tblSafeToDelete
  , tableSetKey = tblSetKey
  , tableGetKey = tblGetKey
  , tableComments = tblComments
  }

unsafeSquashPrimaryKey :: TableParams entity -> entity key1 -> forall key2. entity key2
unsafeSquashPrimaryKey params = tblSetKey params (error "Primary key field was used!")

data RelationalMap a b where
  RM_Field :: (Convertible a SqlValue, Convertible SqlValue a)
           => FieldDefinition -> RelationalMap a a

  RM_Nest  :: (a -> b) -> RelationalMap b c -> RelationalMap a c

  RM_Pure  :: b -> RelationalMap a b

  RM_Apply :: RelationalMap a (b -> c)
           -> RelationalMap a b
           -> RelationalMap a c

  RM_Partial :: RelationalMap a (Either String a)
             -> RelationalMap a a

  RM_ReadOnly :: RelationalMap a b -> RelationalMap c b

  RM_MaybeTag :: RelationalMap (Maybe a) (Maybe b)
              -> RelationalMap (Maybe a) (Maybe b)


instance Functor (RelationalMap a) where
  fmap f rm = pure f <*> rm

instance Applicative (RelationalMap a) where
  pure  = RM_Pure
  (<*>) = RM_Apply


mapAttr :: (a -> b) -> RelationalMap b c -> RelationalMap a c
mapAttr = RM_Nest

mapField :: (Convertible a SqlValue, Convertible SqlValue a)
         => FieldDefinition -> RelationalMap a a
mapField = RM_Field

partialMap :: RelationalMap a (Either String a)
           -> RelationalMap a a
partialMap = RM_Partial

readOnlyMap :: RelationalMap a b -> RelationalMap c b
readOnlyMap = RM_ReadOnly

attrField :: (Convertible b SqlValue, Convertible SqlValue b)
          => (a -> b)
          -> FieldDefinition
          -> RelationalMap a b
attrField get = mapAttr get . mapField

prefixMap :: String -> RelationalMap a b -> RelationalMap a b
prefixMap prefix (RM_Nest f rm) = RM_Nest f (prefixMap prefix rm)
prefixMap prefix (RM_Field f) = RM_Field (f `withPrefix` prefix)
prefixMap prefix (RM_Apply rmF rmA) = RM_Apply (prefixMap prefix rmF)
                                               (prefixMap prefix rmA)

prefixMap prefix (RM_Partial rm) = RM_Partial (prefixMap prefix rm)
prefixMap prefix (RM_ReadOnly rm) = RM_ReadOnly (prefixMap prefix rm)
prefixMap prefix (RM_MaybeTag rm) = RM_MaybeTag (prefixMap prefix rm)
prefixMap _ rm@(RM_Pure _) = rm

maybeMapper :: RelationalMap a b -> RelationalMap (Maybe a) (Maybe b)
maybeMapper =
    -- rewrite the mapper to handle null fields, then tag
    -- it as having been done so we don't double-map it
    -- in a future `maybeMapper` call.
    --
    RM_MaybeTag . go
  where
    go :: RelationalMap a b -> RelationalMap (Maybe a) (Maybe b)
    go (RM_Nest f rm) = RM_Nest (fmap f) (go rm)
    go (RM_Field f) = RM_Field (f `withFlag` Null)
    go (RM_Pure a) = RM_Pure (pure a)
    go (RM_Apply rmF rmA) = RM_Apply (fmap (<*>) $ go rmF)
                                              (go rmA)

    go (RM_Partial rm) =
        RM_Partial (flipError <$> go rm)
      where
        flipError :: Maybe (Either String a) -> Either String (Maybe a)
        flipError (Just (Right a)) = Right (Just a)
        flipError (Just (Left err)) = Left err
        flipError Nothing = Right Nothing

    go (RM_ReadOnly rm) = RM_ReadOnly (go rm)

    go rm@(RM_MaybeTag _) =
        fmap    Just
      $ mapAttr join
      $ rm


fields :: RelationalMap a b -> [FieldDefinition]
fields (RM_Field field) = [field]
fields (RM_Apply rm1 rm2) = fields rm1 ++ fields rm2
fields (RM_Nest _ rm) = fields rm
fields (RM_Partial rm) = fields rm
fields (RM_MaybeTag rm) = fields rm
fields (RM_Pure _) = []
fields (RM_ReadOnly _) = []

mkFromSql :: RelationalMap a b -> FromSql b
mkFromSql (RM_Field field) = col field
mkFromSql (RM_Nest _ rm) = mkFromSql rm
mkFromSql (RM_ReadOnly rm) = mkFromSql rm
mkFromSql (RM_MaybeTag rm) = mkFromSql rm
mkFromSql (RM_Pure b) = pure b
mkFromSql (RM_Apply rmF rmC) = mkFromSql rmF <*> mkFromSql rmC
mkFromSql (RM_Partial rm) = do
    joinFromSqlError (wrapError <$> mkFromSql rm)
  where
    wrapError = either (Left . RowDataError) Right

mkToSql :: RelationalMap a b -> ToSql a ()
mkToSql (RM_Field field) =
  when (not $ isUninsertedField field) $ do
    value <- ask
    modify (convert value:)

mkToSql (RM_Nest f rm) = getComponent f (mkToSql rm)
mkToSql (RM_Apply rmF rmC) = mkToSql rmF >> mkToSql rmC
mkToSql (RM_Partial rm) = mkToSql rm
mkToSql (RM_MaybeTag rm) = mkToSql rm
mkToSql (RM_ReadOnly _) = pure ()
mkToSql (RM_Pure _) = pure ()
