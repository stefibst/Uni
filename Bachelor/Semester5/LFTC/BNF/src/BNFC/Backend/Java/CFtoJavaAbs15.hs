{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}
{-
    BNF Converter: Java 1.5 Abstract Syntax
    Copyright (C) 2004  Author:  Michael Pellauer, Bjorn Bringert

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
-}

{-
   **************************************************************
    BNF Converter Module

    Description   : This module generates the Java Abstract Syntax
                    It uses the BNFC.Backend.Common.NamedVariables module for variable
                    naming. It returns a list of file names, and the
                    contents to be written into that file. (In Java
                    public classes must go in their own file.)

                    The generated classes also support the Visitor
                    Design Pattern.

    Author        : Michael Pellauer (pellauer@cs.chalmers.se),
                    Bjorn Bringert (bringert@cs.chalmers.se)

    License       : GPL (GNU General Public License)

    Created       : 24 April, 2003

    Modified      : 16 June, 2004


   **************************************************************
-}

module BNFC.Backend.Java.CFtoJavaAbs15 (cf2JavaAbs, typename, cat2JavaType) where

import Prelude'

import BNFC.CF
import BNFC.Options (RecordPositions(..))
import BNFC.Utils((+++),(++++))
import BNFC.Backend.Common.NamedVariables hiding (IVar, getVars, varName)
import Data.Function (on)
import Data.List
import Data.Char(toLower)
import Data.Maybe (mapMaybe)
import Text.PrettyPrint

--Produces abstract data types in Java.
--These follow Appel's "non-object oriented" version.
--They also allow users to use the Visitor design pattern.

type IVar = (String, Int, String)
-- ^ The type of an instance variable,
--   a number unique to that type,
--   and an optional name (handles typedefs).

-- | The result is a list of files which must be written to disk.
--   The tuple is (FileName, FileContents)

cf2JavaAbs :: String -> String -> CF -> RecordPositions -> [(FilePath, String)]
cf2JavaAbs _ packageAbsyn cf rp =
    concatMap (prData rp header packageAbsyn user) rules
 where
  header = "package " ++ packageAbsyn ++ "; // Java Package generated by the BNF Converter.\n"
  user = [n | (n,_) <- tokenPragmas cf]
  rules = getAbstractSyntax cf

-- | Generates a (possibly abstract) category class, and classes for all its rules.

prData :: RecordPositions -> String -> String -> [UserDef] -> Data ->[(String, String)]
prData rp header packageAbsyn user (cat, rules) =
  categoryClass ++ mapMaybe (prRule rp header packageAbsyn funs user cat) rules
      where
      funs = map fst rules
      categoryClass
          | show cat `elem` funs = [] -- the catgory is also a function, skip abstract class
          | otherwise = [(identCat cat, header ++++
                         unlines [
                                  "public abstract class" +++ cls
                                    +++ "implements java.io.Serializable {",
                                  "  public abstract <R,A> R accept("
                                  ++ cls ++ ".Visitor<R,A> v, A arg);",
                                  prVisitor packageAbsyn funs,
                                  "}"
                                 ])]
                where cls = identCat cat

prVisitor :: String -> [String] -> String
prVisitor packageAbsyn funs =
    unlines [
             "  public interface Visitor <R,A> {",
             unlines (map prVisitFun funs),
             "  }"
            ]
    where
    prVisitFun f = "    public R visit(" ++ packageAbsyn ++ "." ++ f ++ " p, A arg);"

-- | Generates classes for a rule, depending on what type of rule it is.

prRule :: RecordPositions     -- ^ Include line number info in generated classes.
       -> String   -- ^ Header.
       -> String   -- ^ Abstract syntax package name.
       -> [String] -- ^ Names of all constructors in the category.
       -> [UserDef] -> Cat -> (Fun, [Cat]) -> Maybe (String, String)
prRule rp h packageAbsyn funs user c (fun, cats)
  | isNilFun fun || isOneFun fun = Nothing  -- these are not represented in the Absyn
  | isConsFun fun = Just . (fun',) . unlines $ -- this is the linked list case.
      [ h
      , unwords [ "public class", fun', "extends", cat2JavaTypeTopList user c, "{" ]
      , "}"
      ]
  | otherwise = Just . (fun,) . unlines $ -- a standard rule
      [ h
      , unwords [ "public class", fun, ext, "{" ]
      , render $ nest 2 $ vcat
          [ prInstVars rp vs
          , prConstructor fun user vs cats
          ]
      , prAccept packageAbsyn c fun
      , prEquals packageAbsyn fun vs
      , prHashCode packageAbsyn fun vs
      , if isAlsoCategory then prVisitor packageAbsyn funs else ""
      , "}"
      ]
   where
     vs = getVars cats user
     fun' = identCat (normCat c)
     isAlsoCategory = fun == show c
     --This handles the case where a LBNF label is the same as the category.
     ext = if isAlsoCategory then "" else " extends" +++ identCat c

-- | The standard accept function for the Visitor pattern.

prAccept :: String -> Cat -> String -> String
prAccept pack cat _ = "\n  public <R,A> R accept(" ++ pack ++ "." ++ show cat
                      ++ ".Visitor<R,A> v, A arg) { return v.visit(this, arg); }\n"

-- | Creates the equals() method.

prEquals :: String -> String -> [IVar] -> String
prEquals pack fun vs =
    unlines $ map ("  "++) $ ["public boolean equals(Object o) {",
                              "  if (this == o) return true;",
                              "  if (o instanceof " ++ fqn ++ ") {"]
                              ++ (if null vs
                                     then ["    return true;"]
                                     else ["    " ++ fqn +++ "x = ("++fqn++")o;",
                                           "    return " ++ checkKids ++ ";"]) ++
                             ["  }",
                              "  return false;",
                              "}"]
  where
  fqn = pack++"."++fun
  checkKids = intercalate " && " $ map checkKid vs
  checkKid iv = "this." ++ v ++ ".equals(x." ++ v ++ ")"
      where v = render (iVarName iv)

-- | Creates the equals() method.

prHashCode :: String -> String -> [IVar] -> String
prHashCode _ _ vs =
    unlines $ map ("  "++) ["public int hashCode() {",
                            "  return " ++ hashKids vs ++ ";",
                            "}"
                           ]
  where
  aPrime = 37
  hashKids [] = show aPrime
  hashKids (v:vs) = hashKids_ (hashKid v) vs
  hashKids_ = foldl (\r v -> show aPrime ++ "*" ++ "(" ++ r ++ ")+" ++ hashKid v)
  hashKid iv = "this." ++ render (iVarName iv) ++ ".hashCode()"


-- | A class's instance variables.
--
-- >>> prInstVars NoRecordPositions [("A",1,""), ("B",1,""), ("A",2,"abc")]
-- public final A _1, abc_2;
-- public final B _1;
--
-- >>> prInstVars RecordPositions [("A",1,""), ("B",1,""), ("A",2,"abc")]
-- public final A _1, abc_2;
-- public final B _1;
-- public int line_num, col_num, offset;

prInstVars :: RecordPositions -> [IVar] -> Doc
prInstVars rp [] = case rp of
  RecordPositions -> "public int line_num, col_num, offset;"
  NoRecordPositions -> empty
prInstVars rp vars@((t,_,_):_) =
    "public" <+> "final" <+> text t <+> uniques <> ";" $$ prInstVars rp vs'
 where
   (uniques, vs') = prUniques t vars
   --these functions group the types together nicely
   prUniques :: String -> [IVar] -> (Doc, [IVar])
   prUniques t vs = (prVars vs (findIndices (\(y,_,_) ->  y == t) vs), remType t vs)
   prVars vs = hsep . punctuate comma . map (iVarName . (vs!!))
   remType :: String -> [IVar] -> [IVar]
   remType _ [] = []
   remType t ((t2,n,nm):ts)
    | t == t2 = remType t ts
    | otherwise = (t2,n,nm) : remType t ts

-- | Convert IVar to java name.
--
-- >>> iVarName ("A",1,"abc")
-- abc_1
--
-- >>> iVarName ("C", 2, "")
-- _2
--
-- >>> iVarName ("Integer", 0, "integer")
-- integer_

iVarName :: IVar -> Doc
iVarName (_,n,nm) = text (varName nm) <> text (showNum n)

-- | The constructor just assigns the parameters to the corresponding instance
-- variables.
--
-- >>> prConstructor "bla" [] [("A",1,"a"),("B",1,""),("A",2,"")] [Cat "A",Cat "B", Cat "C"]
-- public bla(A p1, B p2, C p3) { a_1 = p1; _ = p2; _2 = p3; }
--
-- >>> prConstructor "EInt" [] [("Integer",0,"integer")] [Cat "Integer"]
-- public EInt(Integer p1) { integer_ = p1; }

prConstructor :: String -> [UserDef] -> [IVar] -> [Cat] -> Doc
prConstructor c u vs cats =
    "public" <+> text c <> parens (interleave types params)
    <+> "{" <+> text (prAssigns vs params) <> "}"
  where
   (types, params) = unzip (prParams cats u (length cats) (length cats+1))
   interleave xs ys = hsep $ punctuate "," $ zipWith ((<+>) `on` text) xs ys

-- | Prints the parameters to the constructors.

prParams :: [Cat] -> [UserDef] -> Int -> Int -> [(String,String)]
prParams [] _ _ _ = []
prParams (c:cs) u n m = (typename (identCat c) u, 'p' : show (m-n))
                        : prParams cs u (n-1) m

-- | This algorithm peeks ahead in the list so we don't use @map@ or @fold@.

prAssigns :: [IVar] -> [String] -> String
prAssigns [] _ = []
prAssigns _ [] = []
prAssigns ((t,n,nm):vs) (p:ps) =
 if n == 1 then
  case findIndices (\x -> case x of (l,_,_) -> l == t) vs of
    [] -> varName nm +++ "=" +++ p ++ ";" +++ prAssigns vs ps
    _ -> varName nm ++ showNum n +++ "=" +++ p ++ ";" +++ prAssigns vs ps
 else varName nm ++ showNum n +++ "=" +++ p ++ ";" +++ prAssigns vs ps

-- | Different than the standard ''BNFC.Backend.Common.NamedVariables'' version
-- because of the user-defined types.

getVars :: [Cat] -> [UserDef] -> [IVar]
getVars cs user = reverse $ singleToZero $ foldl addVar [] (map identCat cs)
 where
  addVar is c = (c', n, c):is
    where c' = typename c user
          n = maximum (1:[n'+1 | (_,n',c'') <- is, c'' == c])
  singleToZero is = [(t,n',nm) | (t,n,nm) <- is,
                     let n' = if length [n | (_,_,n) <- is, n == nm] == 1
                               then 0 else n]

varName :: String -- ^ category name
        -> String -- ^ Variable name
varName c = map toLower c ++ "_"

-- | This makes up for the fact that there's no typedef in Java.

typename :: String -> [UserDef] -> String
typename t user | t == "Ident"            = "String"
                | t == "Char"             = "Character"
                | t `elem` map show user  = "String"
                | otherwise               = t

-- | Print the Java type corresponding to a category.
cat2JavaType :: [UserDef] -> Cat -> String
cat2JavaType user = loop
  where
  loop = \case
    ListCat c -> "List" ++ loop c
    -- ListCat c -> "java.util.LinkedList<" ++ loop c ++ ">"
    c -> typename (show $ normCat c) user

-- | Print the Java type corresponding to a category.
--   The top list is printed as @java.util.LinkedList<...>@.
cat2JavaTypeTopList :: [UserDef] -> Cat -> String
cat2JavaTypeTopList user = \case
  ListCat c -> "java.util.LinkedList<" ++ cat2JavaType user c ++ ">"
  c -> cat2JavaType user c
