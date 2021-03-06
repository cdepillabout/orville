{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
module Database.Orville.Internal.Types where

import            Control.Exception
import            Control.Monad.Except
import            Control.Monad.Reader
import            Control.Monad.State
import            Control.Monad.Writer
import qualified  Data.List as List
import            Data.Typeable
import            Database.HDBC

import qualified  Data.Time as Time

import            Database.Orville.Internal.Expr
import            Database.Orville.Internal.QueryKey

type Record = Int
type CreatedAt = Time.UTCTime
type UpdatedAt = Time.UTCTime
type OccurredAt = Time.UTCTime

data ColumnType =
    AutomaticId
  | ForeignId
  | Text Int
  | VarText Int
  | Date
  | Timestamp
  | Integer
  | BigInteger
  | TextSearchVector
  | Double
  | Boolean

data ColumnFlag =
    PrimaryKey
  | forall a. ColumnDefault a => Default a
  | Null
  | Unique
  | forall entity. References (TableDefinition entity) FieldDefinition

class ColumnDefault a where
  toColumnDefaultSql :: a -> String

data Now = Now

instance ColumnDefault [Char] where
  toColumnDefaultSql s = "'" ++ s ++ "'"

instance ColumnDefault Now where
  toColumnDefaultSql _ = "(now() at time zone 'utc')"

instance ColumnDefault Integer where
  toColumnDefaultSql val = show val

instance ColumnDefault Bool where
  toColumnDefaultSql True = "true"
  toColumnDefaultSql False = "false"


type FieldDefinition = (String, ColumnType, [ColumnFlag])

instance QueryKeyable (String, ColumnType, [ColumnFlag]) where
  queryKey (name, _, _) = QKField name

data FieldUpdate = FieldUpdate {
    fieldUpdateField :: FieldDefinition
  , fieldUpdateValue :: SqlValue
  }

data TableComment = TableComment {
    tcWhat :: String
  , tcWhen :: (Int, Int, Int)
  , tcWho :: String
  }

newtype TableComments a = TableComments (Writer [TableComment] a)
  deriving (Functor, Applicative, Monad)

runComments :: TableComments a -> [TableComment]
runComments (TableComments commenter) = snd (runWriter commenter)

noComments :: TableComments ()
noComments = return ()

say :: String -> (Int, Int, Int) -> String -> TableComments ()
say msg date commenter = TableComments $
  writer ((), [TableComment msg date commenter])

data FromSqlError =
    RowDataError String
  | QueryError String
  deriving (Show, Typeable)

instance Exception FromSqlError

data FromSql a = FromSql
  { fromSqlSelects :: [SelectForm]
  , runFromSql :: [(String, SqlValue)] -> Either FromSqlError a
  }

instance Functor FromSql where
  fmap f fA = fA { runFromSql = \values -> f <$> runFromSql fA values }

instance Applicative FromSql where
  pure a = FromSql [] (\_ -> pure a)
  fF <*> fA = FromSql
    { fromSqlSelects = fromSqlSelects fF ++ fromSqlSelects fA
    , runFromSql = \values -> runFromSql fF values <*> runFromSql fA values
    }

getColumn :: SelectForm -> FromSql SqlValue
getColumn selectForm = FromSql
  { fromSqlSelects = [selectForm]
  , runFromSql = \values -> do
      let output = unescapedName $ selectFormOutput selectForm

      case lookup output values of
        Just sqlValue -> pure sqlValue
        Nothing ->
          throwError $ QueryError $ concat [ "Column "
                                           , output
                                           , " not found in result set, "
                                           , " actual columns: "
                                           , List.intercalate "," $ map fst values
                                           ]
  }

joinFromSqlError :: FromSql (Either FromSqlError a) -> FromSql a
joinFromSqlError fE = fE { runFromSql = \columns -> join $ runFromSql fE columns }


newtype ToSql a b = ToSql { unToSql :: ReaderT a
                                       (State [SqlValue])
                                       b
                          }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState [SqlValue]
           , MonadReader a
           )

runToSql :: ToSql a b -> a -> [SqlValue]
runToSql tosql a = reverse $ execState (runReaderT (unToSql tosql) a) []

getComponent :: (entity -> a) -> ToSql a () -> ToSql entity ()
getComponent getComp (ToSql serializer) =
  ToSql (withReaderT getComp serializer)

data TableDefinition entity = TableDefinition {
    tableName :: String
  , tableFields :: [FieldDefinition]
  , tableSafeToDelete :: [String]
  , tableFromSql :: FromSql (entity Record)
  , tableToSql :: forall key. ToSql (entity key) ()
  , tableSetKey :: forall key1 key2. key2 -> entity key1 -> entity key2
  , tableGetKey :: forall key. entity key -> key
  , tableComments :: TableComments ()
  }

instance QueryKeyable (TableDefinition entity) where
  queryKey = QKTable . tableName

data SchemaItem =
    forall entity. Table (TableDefinition entity)
  | DropTable String

  | Index IndexDefinition
  | DropIndex String

  | Constraint ConstraintDefinition
  | DropConstraint String String

instance Show SchemaItem where
  show (Table tableDef) = "Table <" ++ tableName tableDef ++ " definition>"
  show (DropTable name) = "DropTable " ++ show name
  show (Index indexDef) = "Index (" ++ show indexDef ++ ")"
  show (DropIndex name) = "DropIndex " ++ show name
  show (Constraint cons) = "Constraint (" ++ show cons ++ ")"
  show (DropConstraint name table) = "DropConstraint " ++ show name ++ " " ++ show table

type SchemaDefinition = [SchemaItem]

data IndexDefinition = IndexDefinition {
    indexName :: String
  , indexUnique :: Bool
  , indexTable :: String
  , indexBody :: String
  } deriving (Eq, Show)

data ConstraintDefinition = ConstraintDefinition {
    constraintName :: String
  , constraintTable :: String
  , constraintBody :: String
  } deriving (Eq, Show)

