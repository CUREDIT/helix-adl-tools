{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module ADL.Sql.SchemaUtils
  ( schemaFromAdl
  , sqlFromSchema
  , columnFromField
  , columnTypeFromField
  , typeExprReferences
  , instantType
  , localDateType
  , localDateTimeType
  ) where

import qualified Data.Aeson as JS
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Vector as V

import ADL.Compiler.Primitive
import ADL.Compiler.AST
import ADL.Compiler.Processing
import ADL.Utils.IndentedCode
import ADL.Utils.Format
import ADL.Sql.Schema
import Data.List(intersperse, sort)
import Data.Monoid
import Cases(snakify)
import Data.Maybe(mapMaybe)

type RTypeExpr = TypeExpr ResolvedType
type RField = Field ResolvedType
type RAnnotations = Annotations ResolvedType
type DBTable = (RDecl,Struct ResolvedType,JS.Value)

-- Build an abstract db schema from an ADL module
schemaFromAdl :: (RField -> Column) -> RModule -> Schema
schemaFromAdl mkColumn mod = Schema
  { schema_adlModules = [formatText (m_name mod)]
  , schema_tables = tables
  }
  where
    tables = map (mkTable mkColumn) (mapMaybe matchDBTable (M.elems (m_decls mod)))

instance Monoid Schema where
  mempty = Schema [] []
  mappend (Schema m1 t1) (Schema m2 t2) = Schema (m1 <> m2) (t1 <> t2)

-- Produce the SQL corresponding to the schema
sqlFromSchema :: Schema -> Code
sqlFromSchema schema =  sql
  where
    sql
      =  ctemplate "-- Schema auto-generated from adl modules: $1" [T.intercalate ", " (sort (schema_adlModules schema))]
      <> cline "--"
      <> cline "-- column comments show original ADL types"
      <> cline ""
      <> mconcat (intersperse (cline "") (map tableDefSql (schema_tables schema)))
      <> cline ""
      <> mconcat (map tableConstraintsSql (schema_tables schema))

tableDefSql :: Table -> Code
tableDefSql table
  =  ctemplate "create table $1(" [table_name table]
  <> indent (mconcat
       [ linefn mcomma | (linefn,mcomma) <- withCommas linefns]
     )
  <> cline ");"
  where
    linefns
      =  map sqlFromColumn (table_columns table)
      <> mkPrimaryKey

    sqlFromColumn col mcomma = cline (column_name col <> " " <> sqltype <> mcomma <> comment)
      where
        sqltype = column_ctype col <> nullable
        nullable | column_nullable col = ""
                 | otherwise = " not null"
        comment | column_comment col == "" = ""
                | otherwise                = template "$1-- $2" [pad,column_comment col]
        pad = T.replicate (max 1 (35 - T.length (column_name col <> sqltype))) " "

    mkPrimaryKey = case table_primaryKey table of
       [] -> []
       pk -> [\mcomma -> cline (template "primary key($1)" [T.intercalate ", " pk])]

tableConstraintsSql :: Table -> Code
tableConstraintsSql table = rconstraints <> uconstraints <> indexes
  where
    rconstraints = mconcat [ ctemplate "alter table $1 add constraint $1_$2_fk foreign key ($2) references $3($4);"
                             [table_name table, column_name col,ftable,fname]
                           | col@Column{column_references=(Just (ForeignKeyRef ftable fname))} <- table_columns table]
    uconstraints = mconcat [ ctemplate "alter table $1 add constraint $1_$2_con unique ($3);"
                             [table_name table, T.pack (show i), T.intercalate ", " (map dbName uc)]
                           | (UniqueConstraint uc,i) <- zip (table_uniqueConstraints table) [1,2..]]
    indexes      = mconcat [ ctemplate "create index $1_$2_idx on $1($3);"
                             [table_name table, T.pack (show i), T.intercalate ", " (map dbName ti)]
                           | (TableIndex ti,i) <- zip (table_indexes table) [1,2..]]


mkTable :: (RField -> Column) -> DBTable -> Table
mkTable mkColumn (decl,struct,ann) = Table
  { table_name = tableName
  , table_columns = idColumn <> map mkColumn (s_fields struct)
  , table_uniqueConstraints = map UniqueConstraint uconstraints
  , table_indexes = map TableIndex indexes
  , table_primaryKey = primaryKey
  , table_annotation = ann
  }
  where
    tableName = case getLiteralField ann "tableName" of
      (Just lit) | lit /= "" -> fromLitString lit
      _ -> dbName (d_name decl)

    uconstraints :: [[T.Text]]
    uconstraints = case getLiteralField ann "uniquenessConstraints" of
      Nothing -> []
      Just lit ->  fromLitArray (fromLitArray fromLitString) lit

    indexes :: [[T.Text]]
    indexes = case getLiteralField ann "indexes" of
      Nothing -> []
      Just lit ->  fromLitArray (fromLitArray fromLitString) lit

    idColumn :: [Column]
    idColumn = case getLiteralField ann "withIdPrimaryKey" of
      Just (JS.Bool True) ->  [Column "id" "text" "" False Nothing]
      _ -> []

    primaryKey :: [T.Text]
    primaryKey = case getLiteralField ann "withPrimaryKey" of
      Just (JS.String k) ->  [k]
      Just lit@(JS.Array _) -> fromLitArray fromLitString lit
      Nothing -> case getLiteralField ann "withIdPrimaryKey" of
        Just (JS.Bool True) -> ["id":: T.Text]
        _ -> []

    fromLitArray f (JS.Array a) = map f (V.toList a)
    fromLitString (JS.String s) = s
    fromLitBool (JS.Bool b) = b

type BoundTypeVariables c = M.Map Ident (TypeExpr (ResolvedTypeT c))

data RawColumn c = RawColumn {
  -- The schema column details
  rc_column:: Column,

  -- The ADL type of the column after resolving type parameters, type aliases, nullability etc
  rc_adltype :: TypeExpr (ResolvedTypeT c)
}

columnFromField :: Field (ResolvedTypeT c) -> Column
columnFromField field = rc_column (rawColumnFromField field)

columnTypeFromField :: Field (ResolvedTypeT c) -> TypeExpr (ResolvedTypeT c)
columnTypeFromField field = rc_adltype (rawColumnFromField field)


rawColumnFromField :: forall c . Field (ResolvedTypeT c) -> RawColumn c
rawColumnFromField field = mkColumn M.empty False (f_type field)
  where
    mkColumn :: BoundTypeVariables c -> Bool -> TypeExpr (ResolvedTypeT c) -> RawColumn c

    -- First consider Maybe<> and Nullable<> as they will switch the column
    -- to support nulls
    mkColumn btv False (TypeExpr (RT_Named (sn,_)) [te]) | sn == maybeType = mkColumn btv True te
    mkColumn btv False (TypeExpr (RT_Primitive P_Nullable) [te]) = mkColumn btv True te

    -- Now consider the special cases for DbKey<>, Instant, LocalDate, and enumerations
    mkColumn _ nullable te@(TypeExpr (RT_Named (sn1,_)) [TypeExpr (RT_Named (sn2,_)) []]) | sn1 ==  dbKeyType =
      mkIdColumn sn2 nullable te
    mkColumn _ nullable te
      | typeExprReferences instantType te = mkRawColumn nullable "timestamp" te
      | typeExprReferences localDateType te = mkRawColumn nullable "date" te
      | typeExprReferences localDateTimeType te = mkRawColumn nullable "timestamp" te
    mkColumn _ nullable te@(TypeExpr ref [])  | isEnumeration2 ref =
      mkRawColumn nullable "text" te

    -- typedefs and newtypes are expanded, doing the right thing with type parameters
    mkColumn btv nullable (TypeExpr (RT_Named (_,Decl{d_type=Decl_Typedef t})) tes) =
      let btv' = createBoundTypeVariables btv (t_typeParams t) (tes)
      in mkColumn btv' nullable (t_typeExpr t)
    mkColumn btv nullable (TypeExpr (RT_Named (_,Decl{d_type=Decl_Newtype n})) tes) =
      let btv' = createBoundTypeVariables btv (n_typeParams n) (tes)
      in mkColumn btv' nullable (n_typeExpr n)
    mkColumn btv nullable (TypeExpr (RT_Param p) []) =
      let te = case M.lookup p btv of
             Nothing -> error ("BUG: unknown type variable " <> (T.unpack p))
             Just te -> te
      in mkColumn btv nullable te

    -- Primitives
    mkColumn _ nullable te@(TypeExpr (RT_Primitive p) _) =
      mkRawColumn nullable (primColumnType p) te

    -- For any other types, just store as json
    mkColumn _ nullable te =
      mkRawColumn nullable "json" te

    columnName = case getAnnotation (f_annotations field) dbColumnNameType of
      Just (JS.String columnName) -> columnName
      Nothing -> dbName (f_name field)

    mkIdColumn :: ScopedName -> Bool ->  TypeExpr (ResolvedTypeT c) -> RawColumn c
    mkIdColumn sn nullable te = RawColumn col te
      where
        col = Column
          { column_name = columnName
          , column_ctype = "text"
          , column_comment = typeExprText (f_type field)
          , column_nullable = nullable
          , column_references = Just (ForeignKeyRef (dbName (sn_name sn)) "id")
          }

    mkRawColumn :: Bool -> T.Text -> TypeExpr (ResolvedTypeT c) -> RawColumn c
    mkRawColumn nullable ctype te = RawColumn col te
      where
        col = Column
          { column_name = columnName
          , column_ctype = ctype
          , column_comment = typeExprText (f_type field)
          , column_nullable = nullable
          , column_references = Nothing
          }


createBoundTypeVariables :: BoundTypeVariables c -> [Ident] -> [TypeExpr (ResolvedTypeT c)] -> BoundTypeVariables c
createBoundTypeVariables btv names types = M.union btv (M.fromList (zip names types))

primColumnType p =  case p of
  P_String -> "text"
  P_Int8 -> "smalllint"
  P_Int16 -> "smalllint"
  P_Int32 -> "integer"
  P_Int64 -> "bigint"
  P_Word8 -> "smalllint"
  P_Word16 -> "smalllint"
  P_Word32 -> "integer"
  P_Word64 -> "bigint"
  P_Float -> "real"
  P_Double -> "double precision"
  P_Bool -> "boolean"
  _ -> "json"

-- match structs that are annotated to be
-- database tables
matchDBTable :: RDecl -> Maybe DBTable
matchDBTable decl = case d_type decl of
  (Decl_Struct struct) ->
    case getAnnotation (d_annotations decl) dbTableType of
      Nothing -> Nothing
      (Just annotation) -> Just (decl,struct,annotation)
  _ -> Nothing

getAnnotation :: Annotations (ResolvedTypeT c)-> ScopedName -> Maybe JS.Value
getAnnotation annotations annotationName = snd <$> (M.lookup annotationName annotations)

typeExprText :: TypeExpr (ResolvedTypeT c) -> T.Text
typeExprText (TypeExpr tr [])  = typeRefText tr
typeExprText (TypeExpr tr tes)  = typeRefText tr <> "<" <>  T.intercalate "," (map typeExprText tes) <> ">"

typeRefText :: ResolvedTypeT c -> T.Text
typeRefText (RT_Primitive p) = formatText p
typeRefText (RT_Param p) = p
typeRefText (RT_Named (ScopedName (ModuleName mname) name,_))
   | null mname = name
   | otherwise   = T.intercalate "." mname <> "." <> name
-- | A type is an enumeration if it's a union with all void fields.

isEnumeration2 :: ResolvedTypeT c -> Bool
isEnumeration2 (RT_Named (ScopedName mname name,Decl{d_type=Decl_Union u})) = isEnumeration u
isEnumeration2 _ = False

----------------------------------------------------------------------
dbName :: T.Text -> T.Text
dbName = snakify

getLiteralField :: JS.Value -> T.Text -> Maybe JS.Value
getLiteralField (JS.Object map) field = HM.lookup field map
getLiteralField _ _ = Nothing

withCommas :: [a] -> [(a,T.Text)]
withCommas [] = []
withCommas [l] = [(l," ")]
withCommas (l:ls) = (l,","):withCommas ls

typeExprReferences :: ScopedName -> TypeExpr (ResolvedTypeT c) -> Bool
typeExprReferences scopedName (TypeExpr (RT_Named (sn,_)) _) | sn == scopedName = True
typeExprReferences _ _ = False

dbTableType = ScopedName (ModuleName ["common","db"]) "DbTable"
dbColumnNameType = ScopedName (ModuleName ["common","db"]) "DbColumnName"
dbKeyType = ScopedName (ModuleName ["common","db"]) "DbKey"
pkType = ScopedName (ModuleName ["common","db"]) "PK"
instantType = ScopedName (ModuleName ["common"]) "Instant"
localDateType = ScopedName (ModuleName ["common"]) "LocalDate"
localDateTimeType = ScopedName (ModuleName ["common"]) "LocalDateTime"
maybeType = ScopedName (ModuleName ["sys","types"]) "Maybe"
