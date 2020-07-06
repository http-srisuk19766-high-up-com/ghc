--
--  (c) The University of Glasgow 2002-2006
--

-- Functions over HsSyn specialised to RdrName.

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -Wno-incomplete-record-updates #-}

module GHC.Parser.PostProcess (
        mkHsOpApp,
        mkHsIntegral, mkHsFractional, mkHsIsString,
        mkHsDo, mkSpliceDecl,
        mkRoleAnnotDecl,
        mkClassDecl,
        mkTyData, mkDataFamInst,
        mkTySynonym, mkTyFamInstEqn,
        mkStandaloneKindSig,
        mkTyFamInst,
        mkFamDecl, mkLHsSigType, mkLHsSigTypeA,
        mkInlinePragma,
        mkPatSynMatchGroup,
        mkRecConstrOrUpdate, -- HsExp -> [HsFieldUpdate] -> P HsExp
        mkTyClD, mkInstD,
        mkRdrRecordCon, mkRdrRecordUpd,
        setRdrNameSpace,
        filterCTuple,
        fromSpecTyVarBndr, fromSpecTyVarBndrs,

        cvBindGroup,
        cvBindsAndSigs,
        cvTopDecls,
        placeHolderPunRhs,

        -- Stuff to do with Foreign declarations
        mkImport,
        parseCImport,
        mkExport,
        mkExtName,    -- RdrName -> CLabelString
        mkGadtDecl,   -- [LocatedA RdrName] -> LHsType RdrName -> ConDecl RdrName
        mkConDeclH98,

        -- Bunch of functions in the parser monad for
        -- checking and constructing values
        checkImportDecl,
        checkExpBlockArguments, checkCmdBlockArguments,
        checkPrecP,           -- Int -> P Int
        checkContext,         -- HsType -> P HsContext
        checkPattern,         -- HsExp -> P HsPat
        checkPattern_msg,
        checkMonadComp,       -- P (HsStmtContext RdrName)
        checkValDef,          -- (SrcLoc, HsExp, HsRhs, [HsDecl]) -> P HsDecl
        checkValSigLhs,
        LRuleTyTmVar, RuleTyTmVar(..),
        mkRuleBndrs, mkRuleTyVarBndrs,
        checkRuleTyVarBndrNames,
        checkRecordSyntax,
        checkEmptyGADTs,
        addFatalError, hintBangPat,
        TyEl(..), mergeOps, mergeDataCon,
        mkBangTy,

        -- Help with processing exports
        ImpExpSubSpec(..),
        ImpExpQcSpec(..),
        mkModuleImpExp,
        mkTypeImpExp,
        mkImpExpSubSpec,
        checkImportSpec,

        -- Token symbols
        forallSym,
        starSym,

        -- Warnings and errors
        warnStarIsType,
        warnPrepositiveQualifiedModule,
        failOpFewArgs,
        failOpNotEnabledImportQualifiedPost,
        failOpImportQualifiedTwice,

        SumOrTuple (..),

        -- Expression/command/pattern ambiguity resolution
        PV,
        runPV,
        ECP(ECP, runECP_PV),
        runECP_P,
        DisambInfixOp(..),
        DisambECP(..),
        ecpFromExp,
        ecpFromCmd,
        PatBuilder
    ) where

import GHC.Prelude
import GHC.Hs           -- Lots of it
import GHC.Core.TyCon          ( TyCon, isTupleTyCon, tyConSingleDataCon_maybe )
import GHC.Core.DataCon        ( DataCon, dataConTyCon )
import GHC.Core.ConLike        ( ConLike(..) )
import GHC.Core.Coercion.Axiom ( Role, fsFromRole )
import GHC.Types.Name.Reader
import GHC.Types.Name
import GHC.Unit.Module (ModuleName)
import GHC.Types.Basic
import GHC.Parser.Lexer
import GHC.Utils.Lexeme ( isLexCon )
import GHC.Core.Type    ( TyThing(..), unrestrictedFunTyCon, Specificity(..) )
import GHC.Builtin.Types( cTupleTyConName, tupleTyCon, tupleDataCon,
                          nilDataConName, nilDataConKey,
                          listTyConName, listTyConKey, eqTyCon_RDR,
                          tupleTyConName, cTupleTyConNameArity_maybe )
import GHC.Types.ForeignCall
import GHC.Builtin.Names ( allNameStrings )
import GHC.Types.SrcLoc
import GHC.Types.Unique ( hasKey )
import GHC.Data.OrdList ( OrdList, fromOL )
import GHC.Data.Bag     ( emptyBag, consBag )
import GHC.Utils.Outputable as Outputable
import GHC.Data.FastString
import GHC.Data.Maybe
import GHC.Utils.Misc
import Data.List
import GHC.Driver.Session ( WarningFlag(..), DynFlags )
import GHC.Utils.Error ( Messages )

import Control.Monad
import Text.ParserCombinators.ReadP as ReadP
import Data.Char
import qualified Data.Monoid as Monoid
import Data.Data       ( dataTypeOf, fromConstr, dataTypeConstrs )
import Data.Kind       ( Type )

#include "HsVersions.h"


{- **********************************************************************

  Construction functions for Rdr stuff

  ********************************************************************* -}

-- | mkClassDecl builds a RdrClassDecl, filling in the names for tycon and
-- datacon by deriving them from the name of the class.  We fill in the names
-- for the tycon and datacon corresponding to the class, by deriving them
-- from the name of the class itself.  This saves recording the names in the
-- interface file (which would be equally good).

-- Similarly for mkConDecl, mkClassOpSig and default-method names.

--         *** See Note [The Naming story] in GHC.Hs.Decls ****

mkTyClD :: LTyClDecl (GhcPass p) -> LHsDecl (GhcPass p)
mkTyClD (L loc d) = L (noAnnSrcSpan loc) (TyClD noExtField d)

mkInstD :: LInstDecl (GhcPass p) -> LHsDecl (GhcPass p)
mkInstD (L loc d) = L (noAnnSrcSpan loc) (InstD noExtField d)

mkClassDecl :: SrcSpan
            -> Located (Maybe (LHsContext GhcPs), LHsType GhcPs)
            -> Located (a,[LHsFunDep GhcPs])
            -> OrdList (LHsDecl GhcPs)
            -> [AddApiAnn]
            -> P (LTyClDecl GhcPs)

mkClassDecl loc (L _ (mcxt, tycl_hdr)) fds where_cls annsIn
  = do { (binds, sigs, ats, at_defs, _, docs) <- cvBindsAndSigs where_cls
       ; (cls, tparams, fixity, ann) <- checkTyClHdr True tycl_hdr
       ; cs1 <- addAnnsAt loc ann -- Add any API Annotations to the top SrcSpan
       ; (tyvars,annst) <- checkTyVars (text "class") whereDots cls tparams
       ; cs2 <- addAnnsAt loc annst -- Add any API Annotations to the top SrcSpan
       ; let anns' = addAnns (ApiAnn (realSrcSpan loc) annsIn []) (ann++annst) (cs1 ++ cs2)
       ; return (L loc (ClassDecl { tcdCExt = anns', tcdCtxt = mcxt
                                  , tcdLName = cls, tcdTyVars = tyvars
                                  , tcdFixity = fixity
                                  , tcdFDs = snd (unLoc fds)
                                  , tcdSigs = mkClassOpSigs sigs
                                  , tcdMeths = binds
                                  , tcdATs = ats, tcdATDefs = at_defs
                                  , tcdDocs  = docs })) }

mkTyData :: SrcSpan
         -> NewOrData
         -> Maybe (LocatedP CType)
         -> Located (Maybe (LHsContext GhcPs), LHsType GhcPs)
         -> Maybe (LHsKind GhcPs)
         -> [LConDecl GhcPs]
         -> Located (HsDeriving GhcPs)
         -> [AddApiAnn]
         -> P (LTyClDecl GhcPs)
mkTyData loc new_or_data cType (L _ (mcxt, tycl_hdr))
         ksig data_cons (L _ maybe_deriv) annsIn
  = do { (tc, tparams, fixity, ann) <- checkTyClHdr False tycl_hdr
       ; cs1 <- addAnnsAt loc ann -- Add any API Annotations to the top SrcSpan [temp]
       ; (tyvars, anns) <- checkTyVars (ppr new_or_data) equalsDots tc tparams
       ; cs2 <- addAnnsAt loc anns -- Add any API Annotations to the top SrcSpan [temp]
       ; let anns' = addAnns (ApiAnn (realSrcSpan loc) annsIn []) (ann ++ anns) (cs1 ++ cs2)
       ; defn <- mkDataDefn new_or_data cType mcxt ksig data_cons maybe_deriv anns'
       ; return (L loc (DataDecl { tcdDExt = anns', -- AZ: do we need these?
                                   tcdLName = tc, tcdTyVars = tyvars,
                                   tcdFixity = fixity,
                                   tcdDataDefn = defn })) }

mkDataDefn :: NewOrData
           -> Maybe (LocatedP CType)
           -> Maybe (LHsContext GhcPs)
           -> Maybe (LHsKind GhcPs)
           -> [LConDecl GhcPs]
           -> HsDeriving GhcPs
           -> ApiAnn
           -> P (HsDataDefn GhcPs)
mkDataDefn new_or_data cType mcxt ksig data_cons maybe_deriv ann
  = do { checkDatatypeContext mcxt
       ; return (HsDataDefn { dd_ext = ann
                            , dd_ND = new_or_data, dd_cType = cType
                            , dd_ctxt = mcxt
                            , dd_cons = data_cons
                            , dd_kindSig = ksig
                            , dd_derivs = maybe_deriv }) }


mkTySynonym :: SrcSpan
            -> LHsType GhcPs  -- LHS
            -> LHsType GhcPs  -- RHS
            -> [AddApiAnn]
            -> P (LTyClDecl GhcPs)
mkTySynonym loc lhs rhs annsIn
  = do { (tc, tparams, fixity, ann) <- checkTyClHdr False lhs
       ; cs1 <- addAnnsAt loc ann -- Add any API Annotations to the top SrcSpan [temp]
       ; (tyvars, anns) <- checkTyVars (text "type") equalsDots tc tparams
       ; cs2 <- addAnnsAt loc anns -- Add any API Annotations to the top SrcSpan [temp]
       ; let anns' = addAnns (ApiAnn (realSrcSpan loc) annsIn []) (ann ++ anns) (cs1 ++ cs2)
       ; return (L loc (SynDecl { tcdSExt = anns'
                                , tcdLName = tc, tcdTyVars = tyvars
                                , tcdFixity = fixity
                                , tcdRhs = rhs })) }

mkStandaloneKindSig
  :: SrcSpan
  -> Located [LocatedN RdrName]   -- LHS
  -> LHsKind GhcPs                -- RHS
  -> [AddApiAnn]
  -> P (LStandaloneKindSig GhcPs)
mkStandaloneKindSig loc lhs rhs anns =
  do { vs <- mapM check_lhs_name (unLoc lhs)
     ; v <- check_singular_lhs (reverse vs)
     ; cs <- addAnnsAt loc []
     ; return $ L loc $ StandaloneKindSig (ApiAnn (realSrcSpan loc) anns cs) v (mkLHsSigType rhs) }
  where
    check_lhs_name v@(unLoc->name) =
      if isUnqual name && isTcOcc (rdrNameOcc name)
      then return v
      else addFatalError (getLocA v) $
           hang (text "Expected an unqualified type constructor:") 2 (ppr v)
    check_singular_lhs vs =
      case vs of
        [] -> panic "mkStandaloneKindSig: empty left-hand side"
        [v] -> return v
        _ -> addFatalError (getLoc lhs) $
             vcat [ hang (text "Standalone kind signatures do not support multiple names at the moment:")
                       2 (pprWithCommas ppr vs)
                  , text "See https://gitlab.haskell.org/ghc/ghc/issues/16754 for details." ]

mkTyFamInstEqn :: SrcSpan
               -> Maybe [LHsTyVarBndr () GhcPs]
               -> LHsType GhcPs
               -> LHsType GhcPs
               -> [AddApiAnn]
               -> P (LTyFamInstEqn GhcPs)
mkTyFamInstEqn loc bndrs lhs rhs anns
  = do { (tc, tparams, fixity, ann) <- checkTyClHdr False lhs
       ; cs <- addAnnsAt loc []
       ; return (L (noAnnSrcSpan loc) $ mkHsImplicitBndrs
                  (FamEqn { feqn_ext    = ApiAnn (realSrcSpan loc) (anns `mappend` ann) cs
                          , feqn_tycon  = tc
                          , feqn_bndrs  = bndrs
                          , feqn_pats   = tparams
                          , feqn_fixity = fixity
                          , feqn_rhs    = rhs })) }

mkDataFamInst :: SrcSpan
              -> NewOrData
              -> Maybe (LocatedP CType)
              -> (Maybe ( LHsContext GhcPs), Maybe [LHsTyVarBndr () GhcPs]
                        , LHsType GhcPs)
              -> Maybe (LHsKind GhcPs)
              -> [LConDecl GhcPs]
              -> Located (HsDeriving GhcPs)
              -> [AddApiAnn]
              -> P (LInstDecl GhcPs)
mkDataFamInst loc new_or_data cType (mcxt, bndrs, tycl_hdr)
              ksig data_cons (L _ maybe_deriv) anns
  = do { (tc, tparams, fixity, ann) <- checkTyClHdr False tycl_hdr
       ; -- AZ:TODO: deal with these comments
       ; cs <- addAnnsAt loc ann -- Add any API Annotations to the top SrcSpan [temp]
       ; let anns' = addAnns (ApiAnn (realSrcSpan loc) ann cs) anns []
       ; defn <- mkDataDefn new_or_data cType mcxt ksig data_cons maybe_deriv anns'
       ; return (L loc (DataFamInstD anns' (DataFamInstDecl (mkHsImplicitBndrs
                  (FamEqn { feqn_ext    = noAnn -- AZ: get anns
                          , feqn_tycon  = tc
                          , feqn_bndrs  = bndrs
                          , feqn_pats   = tparams
                          , feqn_fixity = fixity
                          , feqn_rhs    = defn }))))) }

mkTyFamInst :: SrcSpan
            -> TyFamInstEqn GhcPs
            -> [AddApiAnn]
            -> P (LInstDecl GhcPs)
mkTyFamInst loc eqn anns = do
  cs <- addAnnsAt loc []
  return (L loc (TyFamInstD (ApiAnn (realSrcSpan loc) anns cs) (TyFamInstDecl eqn)))

mkFamDecl :: SrcSpan
          -> FamilyInfo GhcPs
          -> LHsType GhcPs                   -- LHS
          -> Located (FamilyResultSig GhcPs) -- Optional result signature
          -> Maybe (LInjectivityAnn GhcPs)   -- Injectivity annotation
          -> [AddApiAnn]
          -> P (LTyClDecl GhcPs)
mkFamDecl loc info lhs ksig injAnn annsIn
  = do { (tc, tparams, fixity, ann) <- checkTyClHdr False lhs
       ; cs1 <- addAnnsAt loc ann -- Add any API Annotations to the top SrcSpan [temp]
       ; (tyvars, anns) <- checkTyVars (ppr info) equals_or_where tc tparams
       ; cs2 <- addAnnsAt loc anns -- Add any API Annotations to the top SrcSpan [temp]
       ; let anns' = addAnns (ApiAnn (realSrcSpan loc) annsIn []) (ann++anns) (cs1 ++ cs2)
       ; return (L loc (FamDecl anns' (FamilyDecl
                                           { fdExt       = noExtField
                                           , fdInfo      = info, fdLName = tc
                                           , fdTyVars    = tyvars
                                           , fdFixity    = fixity
                                           , fdResultSig = ksig
                                           , fdInjectivityAnn = injAnn }))) }
  where
    equals_or_where = case info of
                        DataFamily          -> empty
                        OpenTypeFamily      -> empty
                        ClosedTypeFamily {} -> whereDots

mkLHsSigTypeA :: [AddApiAnn] -> LHsType GhcPs -> P (LHsSigType GhcPs)
mkLHsSigTypeA anns typ = do
  cs <- addAnnsAt (getLocA typ) []
  return $ (mkLHsSigType typ) { hsib_ext = ApiAnn (realSrcSpan $ getLocA typ) anns cs }

mkSpliceDecl :: LHsExpr GhcPs -> HsDecl GhcPs
-- If the user wrote
--      [pads| ... ]   then return a QuasiQuoteD
--      $(e)           then return a SpliceD
-- but if she wrote, say,
--      f x            then behave as if she'd written $(f x)
--                     ie a SpliceD
--
-- Typed splices are not allowed at the top level, thus we do not represent them
-- as spliced declaration.  See #10945
mkSpliceDecl lexpr@(L loc expr)
  | HsSpliceE _ splice@(HsUntypedSplice {}) <- expr
  = SpliceD noExtField (SpliceDecl noExtField (L (locA loc) splice) ExplicitSplice)

  | HsSpliceE _ splice@(HsQuasiQuote {}) <- expr
  = SpliceD noExtField (SpliceDecl noExtField (L (locA loc) splice) ExplicitSplice)

  | otherwise
  = SpliceD noExtField (SpliceDecl noExtField
                        (L (locA loc) (mkUntypedSplice noAnn BareSplice lexpr))
                              ImplicitSplice)

mkRoleAnnotDecl :: SrcSpan
                -> LocatedN RdrName                -- type being annotated
                -> [Located (Maybe FastString)]    -- roles
                -> ApiAnn
                -> P (LRoleAnnotDecl GhcPs)
mkRoleAnnotDecl loc tycon roles anns
  = do { roles' <- mapM parse_role roles
       ; cs <- addAnnsAt loc []
       ; return $ L loc $ RoleAnnotDecl (addAnns anns [] cs) tycon roles' }
  where
    role_data_type = dataTypeOf (undefined :: Role)
    all_roles = map fromConstr $ dataTypeConstrs role_data_type
    possible_roles = [(fsFromRole role, role) | role <- all_roles]

    parse_role (L loc_role Nothing) = return $ L loc_role Nothing
    parse_role (L loc_role (Just role))
      = case lookup role possible_roles of
          Just found_role -> return $ L loc_role $ Just found_role
          Nothing         ->
            let nearby = fuzzyLookup (unpackFS role)
                  (mapFst unpackFS possible_roles)
            in
            addFatalError loc_role
              (text "Illegal role name" <+> quotes (ppr role) $$
               suggestions nearby)

    suggestions []   = empty
    suggestions [r]  = text "Perhaps you meant" <+> quotes (ppr r)
      -- will this last case ever happen??
    suggestions list = hang (text "Perhaps you meant one of these:")
                       2 (pprWithCommas (quotes . ppr) list)

-- | Converts a list of 'LHsTyVarBndr's annotated with their 'Specificity' to
-- binders without annotations. Only accepts specified variables, and errors if
-- any of the provided binders has an 'InferredSpec' annotation.
fromSpecTyVarBndrs :: [LHsTyVarBndr Specificity GhcPs] -> P [LHsTyVarBndr () GhcPs]
fromSpecTyVarBndrs = mapM fromSpecTyVarBndr

-- | Converts 'LHsTyVarBndr' annotated with its 'Specificity' to one without
-- annotations. Only accepts specified variables, and errors if the provided
-- binder has an 'InferredSpec' annotation.
fromSpecTyVarBndr :: LHsTyVarBndr Specificity GhcPs -> P (LHsTyVarBndr () GhcPs)
fromSpecTyVarBndr bndr = case bndr of
  (L loc (UserTyVar xtv flag idp))     -> (check_spec flag loc)
                                          >> return (L loc $ UserTyVar xtv () idp)
  (L loc (KindedTyVar xtv flag idp k)) -> (check_spec flag loc)
                                          >> return (L loc $ KindedTyVar xtv () idp k)
  where
    check_spec :: Specificity -> SrcSpan -> P ()
    check_spec SpecifiedSpec _   = return ()
    check_spec InferredSpec  loc = addFatalError loc
                                   (text "Inferred type variables are not allowed here")

{- **********************************************************************

  #cvBinds-etc# Converting to @HsBinds@, etc.

  ********************************************************************* -}

-- | Function definitions are restructured here. Each is assumed to be recursive
-- initially, and non recursive definitions are discovered by the dependency
-- analyser.


--  | Groups together bindings for a single function
cvTopDecls :: OrdList (LHsDecl GhcPs) -> [LHsDecl GhcPs]
cvTopDecls decls = go (fromOL decls)
  where
    go :: [LHsDecl GhcPs] -> [LHsDecl GhcPs]
    go []                     = []
    go ((L l (ValD x b)) : ds)
      = L l' (ValD x b') : go ds'
        where (L l' b', ds') = getMonoBind (L l b) ds
    go (d : ds)                    = d : go ds

-- Declaration list may only contain value bindings and signatures.
cvBindGroup :: OrdList (LHsDecl GhcPs) -> P (HsValBinds GhcPs)
cvBindGroup binding
  = do { (mbs, sigs, fam_ds, tfam_insts
         , dfam_insts, _) <- cvBindsAndSigs binding
       ; ASSERT( null fam_ds && null tfam_insts && null dfam_insts)
         return $ ValBinds NoAnnSortKey mbs sigs }

cvBindsAndSigs :: OrdList (LHsDecl GhcPs)
  -> P (LHsBinds GhcPs, [LSig GhcPs], [LFamilyDecl GhcPs]
          , [LTyFamInstDecl GhcPs], [LDataFamInstDecl GhcPs], [LDocDecl])
-- Input decls contain just value bindings and signatures
-- and in case of class or instance declarations also
-- associated type declarations. They might also contain Haddock comments.
cvBindsAndSigs fb = go (fromOL fb)
  where
    go []              = return (emptyBag, [], [], [], [], [])
    go ((L l (ValD _ b)) : ds)
      = do { (bs, ss, ts, tfis, dfis, docs) <- go ds'
           ; return (b' `consBag` bs, ss, ts, tfis, dfis, docs) }
      where
        (b', ds') = getMonoBind (L l b) ds
    go ((L l decl) : ds)
      = do { (bs, ss, ts, tfis, dfis, docs) <- go ds
           ; case decl of
               SigD _ s
                 -> return (bs, L (locA l) s : ss, ts, tfis, dfis, docs)
               TyClD _ (FamDecl _ t)
                 -> return (bs, ss, L (locA l) t : ts, tfis, dfis, docs)
               InstD _ (TyFamInstD { tfid_inst = tfi })
                 -> return (bs, ss, ts, L (locA l) tfi : tfis, dfis, docs)
               InstD _ (DataFamInstD { dfid_inst = dfi })
                 -> return (bs, ss, ts, tfis, L (locA l) dfi : dfis, docs)
               DocD _ d
                 -> return (bs, ss, ts, tfis, dfis, L (locA l) d : docs)
               SpliceD _ d
                 -> addFatalError (locA l) $
                    hang (text "Declaration splices are allowed only" <+>
                          text "at the top level:")
                       2 (ppr d)
               _ -> pprPanic "cvBindsAndSigs" (ppr decl) }

-----------------------------------------------------------------------------
-- Group function bindings into equation groups

getMonoBind :: LHsBind GhcPs -> [LHsDecl GhcPs]
  -> (LHsBind GhcPs, [LHsDecl GhcPs])
-- Suppose      (b',ds') = getMonoBind b ds
--      ds is a list of parsed bindings
--      b is a MonoBinds that has just been read off the front

-- Then b' is the result of grouping more equations from ds that
-- belong with b into a single MonoBinds, and ds' is the depleted
-- list of parsed bindings.
--
-- All Haddock comments between equations inside the group are
-- discarded.
--
-- No AndMonoBinds or EmptyMonoBinds here; just single equations

getMonoBind (L loc1 (FunBind { fun_id = fun_id1@(L _ f1)
                             , fun_matches =
                               MG { mg_alts = (L _ mtchs1) } }))
            binds
  | has_args mtchs1
  = go mtchs1 (locA loc1) binds []
  where
    -- TODO:AZ may have to preserve annotations. Although they should
    -- only be AnnSemi, and meaningless in this context?
    go :: [LMatch GhcPs (LHsExpr GhcPs)] -> SrcSpan
       -> [LHsDecl GhcPs] -> [LHsDecl GhcPs]
       -> (LHsBind GhcPs,[LHsDecl GhcPs]) -- AZ
    go mtchs loc
       ((L loc2 (ValD _ (FunBind { fun_id = (L _ f2)
                                 , fun_matches =
                                    MG { mg_alts = (L _ mtchs2) } })))
         : binds) _
        | f1 == f2 = go (mtchs2 ++ mtchs)
                        (combineSrcSpans loc (locA loc2)) binds []
    go mtchs loc (doc_decl@(L loc2 (DocD {})) : binds) doc_decls
        = let doc_decls' = doc_decl : doc_decls
          in go mtchs (combineSrcSpans loc (locA loc2)) binds doc_decls'
    go mtchs loc binds doc_decls
        = ( L (noAnnSrcSpan loc) (makeFunBind fun_id1 (mkLocatedListA $ reverse mtchs))
          , (reverse doc_decls) ++ binds)
        -- Reverse the final matches, to get it back in the right order
        -- Do the same thing with the trailing doc comments

getMonoBind bind binds = (bind, binds)

has_args :: [LMatch GhcPs (LHsExpr GhcPs)] -> Bool
has_args []                                  = panic "GHC.Parser.PostProcess.has_args"
has_args (L _ (Match { m_pats = args }) : _) = not (null args)
        -- Don't group together FunBinds if they have
        -- no arguments.  This is necessary now that variable bindings
        -- with no arguments are now treated as FunBinds rather
        -- than pattern bindings (tests/rename/should_fail/rnfail002).

{- **********************************************************************

  #PrefixToHS-utils# Utilities for conversion

  ********************************************************************* -}

{- Note [Parsing data constructors is hard]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The problem with parsing data constructors is that they look a lot like types.
Compare:

  (s1)   data T = C t1 t2
  (s2)   type T = C t1 t2

Syntactically, there's little difference between these declarations, except in
(s1) 'C' is a data constructor, but in (s2) 'C' is a type constructor.

This similarity would pose no problem if we knew ahead of time if we are
parsing a type or a constructor declaration. Looking at (s1) and (s2), a simple
(but wrong!) rule comes to mind: in 'data' declarations assume we are parsing
data constructors, and in other contexts (e.g. 'type' declarations) assume we
are parsing type constructors.

This simple rule does not work because of two problematic cases:

  (p1)   data T = C t1 t2 :+ t3
  (p2)   data T = C t1 t2 => t3

In (p1) we encounter (:+) and it turns out we are parsing an infix data
declaration, so (C t1 t2) is a type and 'C' is a type constructor.
In (p2) we encounter (=>) and it turns out we are parsing an existential
context, so (C t1 t2) is a constraint and 'C' is a type constructor.

As the result, in order to determine whether (C t1 t2) declares a data
constructor, a type, or a context, we would need unlimited lookahead which
'happy' is not so happy with.

To further complicate matters, the interpretation of (!) and (~) is different
in constructors and types:

  (b1)   type T = C ! D
  (b2)   data T = C ! D
  (b3)   data T = C ! D => E

In (b1) and (b3), (!) is a type operator with two arguments: 'C' and 'D'. At
the same time, in (b2) it is a strictness annotation: 'C' is a data constructor
with a single strict argument 'D'. For the programmer, these cases are usually
easy to tell apart due to whitespace conventions:

  (b2)   data T = C !D         -- no space after the bang hints that
                               -- it is a strictness annotation

For the parser, on the other hand, this whitespace does not matter. We cannot
tell apart (b2) from (b3) until we encounter (=>), so it requires unlimited
lookahead.

The solution that accounts for all of these issues is to initially parse data
declarations and types as a reversed list of TyEl:

  data TyEl = TyElOpr RdrName
            | TyElOpd (HsType GhcPs)
            | ...

For example, both occurrences of (C ! D) in the following example are parsed
into equal lists of TyEl:

  data T = C ! D => C ! D   results in   [ TyElOpd (HsTyVar "D")
                                         , TyElOpr "!"
                                         , TyElOpd (HsTyVar "C") ]

Note that elements are in reverse order. Also, 'C' is parsed as a type
constructor (HsTyVar) even when it is a data constructor. We fix this in
`tyConToDataCon`.

By the time the list of TyEl is assembled, we have looked ahead enough to
decide whether to reduce using `mergeOps` (for types) or `mergeDataCon` (for
data constructors). These functions are where the actual job of parsing is
done.

-}

-- | Reinterpret a type constructor, including type operators, as a data
--   constructor.
-- See Note [Parsing data constructors is hard]
tyConToDataCon :: LocatedN RdrName -> Either (SrcSpan, SDoc) (LocatedN RdrName)
tyConToDataCon (L loc tc)
  | isTcOcc occ || isDataOcc occ
  , isLexCon (occNameFS occ)
  = return (L loc (setRdrNameSpace tc srcDataName))

  | otherwise
  = Left (locA loc, msg)
  where
    occ = rdrNameOcc tc
    msg = text "Not a data constructor:" <+> quotes (ppr tc)

mkPatSynMatchGroup :: LocatedN RdrName
                   -> LocatedL (OrdList (LHsDecl GhcPs))
                   -> P (MatchGroup GhcPs (LHsExpr GhcPs))
mkPatSynMatchGroup (L loc patsyn_name) (L _ decls) =
    do { matches <- mapM fromDecl (fromOL decls)
       ; when (null matches) (wrongNumberErr (locA loc))
       ; return $ mkMatchGroup FromSource (mkLocatedListA matches) }
  where
    fromDecl :: LHsDecl GhcPs -> P (LMatch GhcPs (LHsExpr GhcPs)) -- AZ
    fromDecl (L loc decl@(ValD _ (PatBind _
                                 -- AZ: where should these anns come from?
                         pat@(L _ (ConPat noAnn ln@(L _ name) details))
                               rhs _))) =
        do { unless (name == patsyn_name) $
               wrongNameBindingErr (locA loc) decl
           ; match <- case details of
               PrefixCon pats -> return $ Match { m_ext = noAnn
                                                , m_ctxt = ctxt, m_pats = pats
                                                , m_grhss = rhs }
                   where
                     ctxt = FunRhs { mc_fun = ln
                                   , mc_fixity = Prefix
                                   , mc_strictness = NoSrcStrict }

               InfixCon p1 p2 -> return $ Match { m_ext = noAnn
                                                , m_ctxt = ctxt
                                                , m_pats = [p1, p2]
                                                , m_grhss = rhs }
                   where
                     ctxt = FunRhs { mc_fun = ln
                                   , mc_fixity = Infix
                                   , mc_strictness = NoSrcStrict }

               RecCon{} -> recordPatSynErr (locA loc) pat
           ; return $ L loc match }
    fromDecl (L loc decl) = extraDeclErr (locA loc) decl

    extraDeclErr loc decl =
        addFatalError loc $
        text "pattern synonym 'where' clause must contain a single binding:" $$
        ppr decl

    wrongNameBindingErr loc decl =
      addFatalError loc $
      text "pattern synonym 'where' clause must bind the pattern synonym's name"
      <+> quotes (ppr patsyn_name) $$ ppr decl

    wrongNumberErr loc =
      addFatalError loc $
      text "pattern synonym 'where' clause cannot be empty" $$
      text "In the pattern synonym declaration for: " <+> ppr (patsyn_name)

recordPatSynErr :: SrcSpan -> LPat GhcPs -> P a
recordPatSynErr loc pat =
    addFatalError loc $
    text "record syntax not supported for pattern synonym declarations:" $$
    ppr pat

mkConDeclH98 :: ApiAnn -> LocatedN RdrName -> Maybe [LHsTyVarBndr Specificity GhcPs]
                -> Maybe (LHsContext GhcPs) -> HsConDeclDetails GhcPs
                -> ConDecl GhcPs

mkConDeclH98 ann name mb_forall mb_cxt args
  = ConDeclH98 { con_ext    = ann
               , con_name   = name
               , con_forall = noLoc $ isJust mb_forall
               , con_ex_tvs = mb_forall `orElse` []
               , con_mb_cxt = mb_cxt
               , con_args   = args
               , con_doc    = Nothing }

-- | Construct a GADT-style data constructor from the constructor names and
-- their type. This will return different AST forms for record syntax
-- constructors and prefix constructors, as the latter must be handled
-- specially in the renamer. See @Note [GADT abstract syntax]@ in
-- "GHC.Hs.Decls" for the full story.
mkGadtDecl :: SrcSpan
           -> ApiAnnComments
           -> [LocatedN RdrName]
           -> LHsType GhcPs
           -> [AddApiAnn]
           -> ConDecl GhcPs
mkGadtDecl loc cs names ty annsIn
  | Just (mtvs, mcxt, args, res_ty) <- mb_record_gadt ty
  = ConDeclGADT { con_g_ext  = ApiAnn (realSrcSpan loc) annsIn cs
                , con_names  = names
                , con_forall = L (getLocA ty) $ isJust mtvs
                , con_qvars  = fromMaybe [] mtvs
                , con_mb_cxt = mcxt
                , con_args   = args
                , con_res_ty = res_ty
                , con_doc    = Nothing }
  | otherwise
  = XConDecl $ ConDeclGADTPrefixPs { con_gp_names = names
                                   , con_gp_ty    = mkLHsSigType ty
                                   , con_gp_doc   = Nothing }
  where
    mb_record_gadt ty
      | (mtvs, mcxt, body_ty) <- splitLHsGADTPrefixTy ty
      , L _ (HsFunTy _ _w (L loc (HsRecTy an rf)) res_ty) <- body_ty
      = Just (mtvs, mcxt, RecCon (L (SrcSpanAnn an (locA loc)) rf), res_ty)
      | otherwise
      = Nothing

setRdrNameSpace :: RdrName -> NameSpace -> RdrName
-- ^ This rather gruesome function is used mainly by the parser.
-- When parsing:
--
-- > data T a = T | T1 Int
--
-- we parse the data constructors as /types/ because of parser ambiguities,
-- so then we need to change the /type constr/ to a /data constr/
--
-- The exact-name case /can/ occur when parsing:
--
-- > data [] a = [] | a : [a]
--
-- For the exact-name case we return an original name.
setRdrNameSpace (Unqual occ) ns = Unqual (setOccNameSpace ns occ)
setRdrNameSpace (Qual m occ) ns = Qual m (setOccNameSpace ns occ)
setRdrNameSpace (Orig m occ) ns = Orig m (setOccNameSpace ns occ)
setRdrNameSpace (Exact n)    ns
  | Just thing <- wiredInNameTyThing_maybe n
  = setWiredInNameSpace thing ns
    -- Preserve Exact Names for wired-in things,
    -- notably tuples and lists

  | isExternalName n
  = Orig (nameModule n) occ

  | otherwise   -- This can happen when quoting and then
                -- splicing a fixity declaration for a type
  = Exact (mkSystemNameAt (nameUnique n) occ (nameSrcSpan n))
  where
    occ = setOccNameSpace ns (nameOccName n)

setWiredInNameSpace :: TyThing -> NameSpace -> RdrName
setWiredInNameSpace (ATyCon tc) ns
  | isDataConNameSpace ns
  = ty_con_data_con tc
  | isTcClsNameSpace ns
  = Exact (getName tc)      -- No-op

setWiredInNameSpace (AConLike (RealDataCon dc)) ns
  | isTcClsNameSpace ns
  = data_con_ty_con dc
  | isDataConNameSpace ns
  = Exact (getName dc)      -- No-op

setWiredInNameSpace thing ns
  = pprPanic "setWiredinNameSpace" (pprNameSpace ns <+> ppr thing)

ty_con_data_con :: TyCon -> RdrName
ty_con_data_con tc
  | isTupleTyCon tc
  , Just dc <- tyConSingleDataCon_maybe tc
  = Exact (getName dc)

  | tc `hasKey` listTyConKey
  = Exact nilDataConName

  | otherwise  -- See Note [setRdrNameSpace for wired-in names]
  = Unqual (setOccNameSpace srcDataName (getOccName tc))

data_con_ty_con :: DataCon -> RdrName
data_con_ty_con dc
  | let tc = dataConTyCon dc
  , isTupleTyCon tc
  = Exact (getName tc)

  | dc `hasKey` nilDataConKey
  = Exact listTyConName

  | otherwise  -- See Note [setRdrNameSpace for wired-in names]
  = Unqual (setOccNameSpace tcClsName (getOccName dc))

-- | Replaces constraint tuple names with corresponding boxed ones.
filterCTuple :: RdrName -> RdrName
filterCTuple (Exact n)
  | Just arity <- cTupleTyConNameArity_maybe n
  = Exact $ tupleTyConName BoxedTuple arity
filterCTuple rdr = rdr


{- Note [setRdrNameSpace for wired-in names]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In GHC.Types, which declares (:), we have
  infixr 5 :
The ambiguity about which ":" is meant is resolved by parsing it as a
data constructor, but then using dataTcOccs to try the type constructor too;
and that in turn calls setRdrNameSpace to change the name-space of ":" to
tcClsName.  There isn't a corresponding ":" type constructor, but it's painful
to make setRdrNameSpace partial, so we just make an Unqual name instead. It
really doesn't matter!
-}

eitherToP :: Either (SrcSpan, SDoc) a -> P a
-- Adapts the Either monad to the P monad
eitherToP (Left (loc, doc)) = addFatalError loc doc
eitherToP (Right thing)     = return thing

checkTyVars :: SDoc -> SDoc -> LocatedN RdrName -> [LHsTypeArg GhcPs]
            -> P ( LHsQTyVars GhcPs  -- the synthesized type variables
                 , [AddApiAnn] )     -- action which adds annotations
-- ^ Check whether the given list of type parameters are all type variables
-- (possibly with a kind signature).
checkTyVars pp_what equals_or_where tc tparms
  = do { (tvs, anns) <- fmap unzip $ mapM check tparms
       ; return (mkHsQTvs tvs, concat anns) }
  where
    check (HsTypeArg _ ki@(L loc _))
                              = addFatalError (locA loc) $
                                      vcat [ text "Unexpected type application" <+>
                                            text "@" <> ppr ki
                                          , text "In the" <+> pp_what <+>
                                            ptext (sLit "declaration for") <+> quotes (ppr tc)]
    check (HsValArg ty) = chkParens [] ty
    check (HsArgPar sp) = addFatalError sp $
                          vcat [text "Malformed" <+> pp_what
                            <+> text "declaration for" <+> quotes (ppr tc)]
        -- Keep around an action for adjusting the annotations of extra parens
    chkParens :: [AddApiAnn] -> LHsType GhcPs
              -> P (LHsTyVarBndr () GhcPs, [AddApiAnn])
    chkParens acc (L l (HsParTy _ ty)) = chkParens (mkParensApiAnn (locA l) ++ acc) ty
    chkParens acc ty = do
      tv <- chk ty
      return (tv, reverse acc)

        -- Check that the name space is correct!
    chk :: LHsType GhcPs -> P (LHsTyVarBndr () GhcPs)
    chk (L l (HsKindSig _ (L _ (HsTyVar ann _ (L lv tv))) k))
        | isRdrTyVar tv    = return (L (locA l) (KindedTyVar ann () (L lv tv) k))
    chk (L l (HsTyVar ann _ (L ltv tv)))
        | isRdrTyVar tv    = return (L (locA l) (UserTyVar ann () (L ltv tv)))
    chk t@(L loc _)
        = addFatalError (locA loc) $
                vcat [ text "Unexpected type" <+> quotes (ppr t)
                     , text "In the" <+> pp_what
                       <+> ptext (sLit "declaration for") <+> quotes tc'
                     , vcat[ (text "A" <+> pp_what
                              <+> ptext (sLit "declaration should have form"))
                     , nest 2
                       (pp_what
                        <+> tc'
                        <+> hsep (map text (takeList tparms allNameStrings))
                        <+> equals_or_where) ] ]

    -- Avoid printing a constraint tuple in the error message. Print
    -- a plain old tuple instead (since that's what the user probably
    -- wrote). See #14907
    tc' = ppr $ fmap filterCTuple tc



whereDots, equalsDots :: SDoc
-- Second argument to checkTyVars
whereDots  = text "where ..."
equalsDots = text "= ..."

checkDatatypeContext :: Maybe (LHsContext GhcPs) -> P ()
checkDatatypeContext Nothing = return ()
checkDatatypeContext (Just c)
    = do allowed <- getBit DatatypeContextsBit
         unless allowed $
             addError (getLocA c)
                 (text "Illegal datatype context (use DatatypeContexts):"
                  <+> pprLHsContext (Just c))

type LRuleTyTmVar = Located RuleTyTmVar
data RuleTyTmVar = RuleTyTmVar ApiAnn (LocatedN RdrName) (Maybe (LHsType GhcPs))
-- ^ Essentially a wrapper for a @RuleBndr GhcPs@

-- turns RuleTyTmVars into RuleBnrs - this is straightforward
mkRuleBndrs :: [LRuleTyTmVar] -> [LRuleBndr GhcPs]
mkRuleBndrs = fmap (fmap cvt_one)
  where cvt_one (RuleTyTmVar ann v Nothing) = RuleBndr ann v
        cvt_one (RuleTyTmVar ann v (Just sig)) =
          RuleBndrSig ann v (mkHsPatSigType sig)

-- turns RuleTyTmVars into HsTyVarBndrs - this is more interesting
mkRuleTyVarBndrs :: [LRuleTyTmVar] -> [LHsTyVarBndr () GhcPs]
mkRuleTyVarBndrs = fmap (fmap cvt_one)
  where cvt_one (RuleTyTmVar ann v Nothing) = UserTyVar ann () (fmap tm_to_ty v)
        cvt_one (RuleTyTmVar ann v (Just sig))
          = KindedTyVar ann () (fmap tm_to_ty v) sig
    -- takes something in namespace 'varName' to something in namespace 'tvName'
        tm_to_ty (Unqual occ) = Unqual (setOccNameSpace tvName occ)
        tm_to_ty _ = panic "mkRuleTyVarBndrs"

-- See note [Parsing explicit foralls in Rules] in Parser.y
checkRuleTyVarBndrNames :: [LHsTyVarBndr flag GhcPs] -> P ()
checkRuleTyVarBndrNames = mapM_ (check . fmap hsTyVarName)
  where check (L loc (Unqual occ)) = do
          when ((occNameString occ ==) `any` ["forall","family","role"])
               (addFatalError loc (text $ "parse error on input "
                                    ++ occNameString occ))
        check _ = panic "checkRuleTyVarBndrNames"

checkRecordSyntax :: (MonadP m, Outputable a) => LocatedA a -> m (LocatedA a)
checkRecordSyntax lr@(L loc r)
    = do allowed <- getBit TraditionalRecordSyntaxBit
         unless allowed $ addError (locA loc) $
           text "Illegal record syntax (use TraditionalRecordSyntax):" <+> ppr r
         return lr

-- | Check if the gadt_constrlist is empty. Only raise parse error for
-- `data T where` to avoid affecting existing error message, see #8258.
checkEmptyGADTs :: Located ([AddApiAnn], [LConDecl GhcPs])
                -> P (Located ([AddApiAnn], [LConDecl GhcPs]))
checkEmptyGADTs gadts@(L span (_, []))           -- Empty GADT declaration.
    = do gadtSyntax <- getBit GadtSyntaxBit   -- GADTs implies GADTSyntax
         unless gadtSyntax $ addError span $ vcat
           [ text "Illegal keyword 'where' in data declaration"
           , text "Perhaps you intended to use GADTs or a similar language"
           , text "extension to enable syntax: data T where"
           ]
         return gadts
checkEmptyGADTs gadts = return gadts              -- Ordinary GADT declaration.

checkTyClHdr :: Bool               -- True  <=> class header
                                   -- False <=> type header
             -> LHsType GhcPs
             -> P (LocatedN RdrName,     -- the head symbol (type or class name)
                   [LHsTypeArg GhcPs],   -- parameters of head symbol
                   LexicalFixity,        -- the declaration is in infix format
                   [AddApiAnn])          -- API Annotation for HsParTy
                                         -- when stripping parens
-- Well-formedness check and decomposition of type and class heads.
-- Decomposes   T ty1 .. tyn   into    (T, [ty1, ..., tyn])
--              Int :*: Bool   into    (:*:, [Int, Bool])
-- returning the pieces
checkTyClHdr is_cls ty
  = goL ty [] [] Prefix
  where
    goL :: LHsType GhcPs
       -> [HsArg (LHsType GhcPs) (LHsKind GhcPs)]
       -> [AddApiAnn]
       -> LexicalFixity
       -> P (LocatedN RdrName,
             [HsArg (LHsType GhcPs) (LHsKind GhcPs)], LexicalFixity, [AddApiAnn]) -- AZ temp
    goL (L l ty) acc ann fix = go (locA l) ty acc ann fix

    -- workaround to define '*' despite StarIsType
    go :: SrcSpan
       -> HsType GhcPs
       -> [HsArg (LHsType GhcPs) (LHsKind GhcPs)]
       -> [AddApiAnn]
       -> LexicalFixity
       -> P (LocatedN RdrName,
             [HsArg (LHsType GhcPs) (LHsKind GhcPs)], LexicalFixity, [AddApiAnn]) -- AZ temp
    go lp (HsParTy _ (L l (HsStarTy _ isUni))) acc ann fix
      = do { warnStarBndr (locA l)
           ; let name = mkOccName tcClsName (starSym isUni)
           ; return (L (la2na l) (Unqual name), acc, fix
                    , (ann ++ mkParensApiAnn lp)) }

    go _ (HsTyVar _ _ ltc@(L _ tc)) acc ann fix
      | isRdrTc tc               = return (ltc, acc, fix, ann)
    go _ (HsOpTy _ t1 ltc@(L _ tc) t2) acc ann _fix
      | isRdrTc tc               = return (ltc, HsValArg t1:HsValArg t2:acc, Infix, ann)
    go l (HsParTy _ ty)    acc ann fix = goL ty acc (ann ++mkParensApiAnn l) fix
    go _ (HsAppTy _ t1 t2) acc ann fix = goL t1 (HsValArg t2:acc) ann fix
    go _ (HsAppKindTy l ty ki) acc ann fix = goL ty (HsTypeArg l ki:acc) ann fix
    go l (HsTupleTy _ HsBoxedOrConstraintTuple ts) [] ann fix
      = return (L (noAnnSrcSpan l) (nameRdrName tup_name)
               , map HsValArg ts, fix, ann)
      where
        arity = length ts
        tup_name | is_cls    = cTupleTyConName arity
                 | otherwise = getName (tupleTyCon Boxed arity)
          -- See Note [Unit tuples] in GHC.Hs.Type  (TODO: is this still relevant?)
    go l _ _ _ _
      = addFatalError l (text "Malformed head of type or class declaration:"
                          <+> ppr ty)

-- | Yield a parse error if we have a function applied directly to a do block
-- etc. and BlockArguments is not enabled.
checkExpBlockArguments :: LHsExpr GhcPs -> PV ()
checkCmdBlockArguments :: LHsCmd GhcPs -> PV ()
(checkExpBlockArguments, checkCmdBlockArguments) = (checkExpr, checkCmd)
  where
    checkExpr :: LHsExpr GhcPs -> PV ()
    checkExpr expr = do
     case unLoc expr of
      HsDo _ (DoExpr m) _ -> check (prependQualified m (text "do block")) expr
      HsDo _ (MDoExpr m) _ -> check (prependQualified m (text "mdo block")) expr
      HsLam {} -> check (text "lambda expression") expr
      HsCase {} -> check (text "case expression") expr
      HsLamCase {} -> check (text "lambda-case expression") expr
      HsLet {} -> check (text "let expression") expr
      HsIf {} -> check (text "if expression") expr
      HsProc {} -> check (text "proc expression") expr
      _ -> return ()

    checkCmd :: LHsCmd GhcPs -> PV ()
    checkCmd cmd = case unLoc cmd of
      HsCmdLam {} -> check (text "lambda command") cmd
      HsCmdCase {} -> check (text "case command") cmd
      HsCmdIf {} -> check (text "if command") cmd
      HsCmdLet {} -> check (text "let command") cmd
      HsCmdDo {} -> check (text "do command") cmd
      _ -> return ()

    check :: Outputable a => SDoc -> LocatedA a -> PV ()
    check element a = do
      blockArguments <- getBit BlockArgumentsBit
      unless blockArguments $
        addError (getLocA a) $
          text "Unexpected " <> element <> text " in function application:"
           $$ nest 4 (ppr a)
           $$ text "You could write it with parentheses"
           $$ text "Or perhaps you meant to enable BlockArguments?"

-- | Validate the context constraints and break up a context into a list
-- of predicates.
--
-- @
--     (Eq a, Ord b)        -->  [Eq a, Ord b]
--     Eq a                 -->  [Eq a]
--     (Eq a)               -->  [Eq a]
--     (((Eq a)))           -->  [Eq a]
-- @
checkContext :: LHsType GhcPs -> P (LHsContext GhcPs)
checkContext orig_t@(L (SrcSpanAnn an l) _orig_t) = do
  check ([],[],[]) orig_t
 where
  check :: ([RealSrcSpan],[RealSrcSpan],[RealLocated AnnotationComment]) -> LHsType GhcPs -> P (LHsContext GhcPs)
  check (oparens,cparens,cs) (L _l (HsTupleTy ann' HsBoxedOrConstraintTuple ts))
    -- (Eq a, Ord b) shows up as a tuple type. Only boxed tuples can
    -- be used as context constraints.
    -- Ditto ()
    = do
        let (op,cp,cs') = case ann' of
              ApiAnnNotUsed -> ([],[],[])
              ApiAnn _ (AnnParen _ o c) cs -> ([o],[c],cs)
        return (L (SrcSpanAnn (ApiAnn (realSrcSpan l) (AnnContext Nothing (op++oparens) (cp++cparens)) (cs++cs')) l) ts)

  check (opi,cpi,csi) (L _lp1 (HsParTy ann' ty))
                                  -- to be sure HsParTy doesn't get into the way
    = do
        let (op,cp,cs') = case ann' of
                    ApiAnnNotUsed -> ([],[],[])
                    ApiAnn _ (AnnParen _ open close ) cs -> ([open],[close],cs)
        check (op++opi,cp++cpi,cs'++csi) ty

  -- no need for anns, returning original
  check (opi,cpi,csi) t = checkNoDocs msg t
                 *> return (L (SrcSpanAnn (ApiAnn (realSrcSpan l) (AnnContext Nothing opi cpi) csi) l) [orig_t])

  msg = text "data constructor context"

-- | Check recursively if there are any 'HsDocTy's in the given type.
-- This only works on a subset of types produced by 'btype_no_ops'
checkNoDocs :: SDoc -> LHsType GhcPs -> P ()
checkNoDocs msg ty = go ty
  where
    go :: LHsType GhcPs -> P () -- AZ
    go (L _ (HsAppKindTy _ ty ki)) = go ty *> go ki
    go (L _ (HsAppTy _ t1 t2)) = go t1 *> go t2
    go (L l (HsDocTy _ t ds)) = addError (locA l) $ hsep
                                  [ text "Unexpected haddock", quotes (ppr ds)
                                  , text "on", msg, quotes (ppr t) ]
    go _ = pure ()

checkImportDecl :: Maybe RealSrcSpan
                -> Maybe RealSrcSpan
                -> P ()
checkImportDecl mPre mPost = do
  let whenJust mg f = maybe (pure ()) f mg

  importQualifiedPostEnabled <- getBit ImportQualifiedPostBit

  -- Error if 'qualified' found in postpositive position and
  -- 'ImportQualifiedPost' is not in effect.
  whenJust mPost $ \post ->
    when (not importQualifiedPostEnabled) $
      failOpNotEnabledImportQualifiedPost (RealSrcSpan post Nothing)

  -- Error if 'qualified' occurs in both pre and postpositive
  -- positions.
  whenJust mPost $ \post ->
    when (isJust mPre) $
      failOpImportQualifiedTwice (RealSrcSpan post Nothing)

  -- Warn if 'qualified' found in prepositive position and
  -- 'Opt_WarnPrepositiveQualifiedModule' is enabled.
  whenJust mPre $ \pre ->
    warnPrepositiveQualifiedModule (RealSrcSpan pre Nothing)

-- -------------------------------------------------------------------------
-- Checking Patterns.

-- We parse patterns as expressions and check for valid patterns below,
-- converting the expression into a pattern at the same time.

checkPattern :: LocatedA (PatBuilder GhcPs) -> P (LPat GhcPs)
checkPattern = runPV . checkLPat

checkPattern_msg :: SDoc -> PV (LocatedA (PatBuilder GhcPs)) -> P (LPat GhcPs)
checkPattern_msg msg pp = runPV_msg msg (pp >>= checkLPat)

checkLPat :: LocatedA (PatBuilder GhcPs) -> PV (LPat GhcPs)
checkLPat e@(L l _) = checkPat (locA l) e []

checkPat :: SrcSpan -> LocatedA (PatBuilder GhcPs) -> [LPat GhcPs]
         -> PV (LPat GhcPs)
checkPat loc (L l e@(PatBuilderVar (L _ c))) args
  | isRdrDataCon c = return . L (noAnnSrcSpan loc) $ ConPat
      { pat_con_ext = noAnn -- AZ: where should this come from?
      , pat_con = L (la2na l) c
      , pat_args = PrefixCon args
      }
  | not (null args) && patIsRec c =
      localPV_msg (\_ -> text "Perhaps you intended to use RecursiveDo") $
      patFail (locA l) (ppr e)
checkPat loc (L _ (PatBuilderApp f e)) args
  = do p <- checkLPat e
       checkPat loc f (p : args)
checkPat loc (L _ e) []
  = do p <- checkAPat loc e
       return (L (noAnnSrcSpan loc) p)
checkPat loc e _
  = patFail loc (ppr e)

checkAPat :: SrcSpan -> PatBuilder GhcPs -> PV (Pat GhcPs)
checkAPat loc e0 = do
 nPlusKPatterns <- getBit NPlusKPatternsBit
 case e0 of
   PatBuilderPat p -> return p
   PatBuilderVar x -> return (VarPat noExtField x)

   -- Overloaded numeric patterns (e.g. f 0 x = x)
   -- Negation is recorded separately, so that the literal is zero or +ve
   -- NB. Negative *primitive* literals are already handled by the lexer
   PatBuilderOverLit pos_lit -> return (mkNPat (L loc pos_lit) Nothing)

   -- n+k patterns
   PatBuilderOpApp
           (L nloc (PatBuilderVar (L _ n)))
           (L _ plus)
           (L lloc (PatBuilderOverLit lit@(OverLit {ol_val = HsIntegral {}})))
           anns
                     | nPlusKPatterns && (plus == plus_RDR)
                     -> return (mkNPlusKPat (L nloc n) (L (locA lloc) lit) anns)

   -- Improve error messages for the @-operator when the user meant an @-pattern
   PatBuilderOpApp _ op _ _ | opIsAt (unLoc op) -> do
     addError (getLocA op) $
       text "Found a binding for the" <+> quotes (ppr op) <+> text "operator in a pattern position." $$
       perhaps_as_pat
     return (WildPat noExtField)

   PatBuilderOpApp l (L cl c) r anns
     | isRdrDataCon c -> do
         l <- checkLPat l
         r <- checkLPat r
         return $ ConPat
           { pat_con_ext = anns
           , pat_con = L (la2na cl) c
           , pat_args = InfixCon l r
           }

   PatBuilderPar e an  -> do
     (L l p) <- checkLPat e
     return (ParPat (ApiAnn (realSrcSpan $ locA l) an []) (L l p))
   _           -> patFail loc (ppr e0)

placeHolderPunRhs :: DisambECP b => PV (LocatedA b)
-- The RHS of a punned record field will be filled in by the renamer
-- It's better not to make it an error, in case we want to print it when
-- debugging
placeHolderPunRhs = mkHsVarPV (noLocA pun_RDR)

plus_RDR, pun_RDR :: RdrName
plus_RDR = mkUnqual varName (fsLit "+") -- Hack
pun_RDR  = mkUnqual varName (fsLit "pun-right-hand-side")

checkPatField :: LHsRecField GhcPs (LocatedA (PatBuilder GhcPs))
              -> PV (LHsRecField GhcPs (LPat GhcPs))
checkPatField (L l fld) = do p <- checkLPat (hsRecFieldArg fld)
                             return (L l (fld { hsRecFieldArg = p }))

patFail :: SrcSpan -> SDoc -> PV a
patFail loc e = addFatalError loc $ text "Parse error in pattern:" <+> ppr e

patIsRec :: RdrName -> Bool
patIsRec e = e == mkUnqual varName (fsLit "rec")

opIsAt :: RdrName -> Bool
opIsAt e = e == mkUnqual varName (fsLit "@")

---------------------------------------------------------------------------
-- Check Equation Syntax

checkValDef :: SrcSpan
            -> LocatedA (PatBuilder GhcPs)
            -> Maybe (AddApiAnn, LHsType GhcPs)
            -> Located (GRHSs GhcPs (LHsExpr GhcPs))
            -> P (HsBind GhcPs)

checkValDef loc lhs (Just (sigAnn, sig)) grhss
        -- x :: ty = rhs  parses as a *pattern* binding
  = do lhs' <- runPV $ mkHsTySigPV (combineLocsA lhs sig) lhs sig [sigAnn]
                        >>= checkLPat
       checkPatBind loc [] lhs' grhss

checkValDef loc lhs Nothing g@(L l grhss)
  = do  { mb_fun <- isFunLhs lhs
        ; case mb_fun of
            Just (fun, is_infix, pats, ann) ->
              checkFunBind NoSrcStrict loc ann (getLocA lhs)
                           fun is_infix pats (L l grhss)
            Nothing -> do
              lhs' <- checkPattern lhs
              checkPatBind loc [] lhs' g }

checkFunBind :: SrcStrictness
             -> SrcSpan
             -> [AddApiAnn]
             -> SrcSpan
             -> LocatedN RdrName
             -> LexicalFixity
             -> [LocatedA (PatBuilder GhcPs)]
             -> Located (GRHSs GhcPs (LHsExpr GhcPs))
             -> P (HsBind GhcPs)
checkFunBind strictness locF ann lhs_loc fun is_infix pats (L rhs_span grhss)
  = do  ps <- runPV_msg param_hint (mapM checkLPat pats)
        let match_span = noAnnSrcSpan $ combineSrcSpans lhs_loc rhs_span
        -- Add back the annotations stripped from any HsPar values in the lhs
        -- mapM_ (\a -> a match_span) ann
        cs <- addAnnsAt locF []
        return (makeFunBind fun (L (noAnnSrcSpan $ locA match_span)
                 [L match_span (Match { m_ext = ApiAnn (realSrcSpan locF) ann cs
                                      , m_ctxt = FunRhs
                                          { mc_fun    = fun
                                          , mc_fixity = is_infix
                                          , mc_strictness = strictness }
                                      , m_pats = ps
                                      , m_grhss = grhss })]))
        -- The span of the match covers the entire equation.
        -- That isn't quite right, but it'll do for now.
  where
    param_hint
      | Infix <- is_infix
      = text "In a function binding for the" <+> quotes (ppr fun) <+> text "operator." $$
        if opIsAt (unLoc fun) then perhaps_as_pat else empty
      | otherwise = empty

perhaps_as_pat :: SDoc
perhaps_as_pat = text "Perhaps you meant an as-pattern, which must not be surrounded by whitespace"

makeFunBind :: LocatedN RdrName -> LocatedL [LMatch GhcPs (LHsExpr GhcPs)]
            -> HsBind GhcPs
-- Like GHC.Hs.Utils.mkFunBind, but we need to be able to set the fixity too
makeFunBind fn ms
  = FunBind { fun_ext = noExtField,
              fun_id = fn,
              fun_matches = mkMatchGroup FromSource ms,
              fun_tick = [] }

-- See Note [FunBind vs PatBind]
checkPatBind :: SrcSpan
             -> [AddApiAnn]
             -> LPat GhcPs
             -> Located (GRHSs GhcPs (LHsExpr GhcPs))
             -> P (HsBind GhcPs)
checkPatBind loc annsIn lhs (L match_span grhss)
    | BangPat _ p <- unLoc lhs
    , VarPat _ v <- unLoc p
    = do
        cs <- addAnnsAt loc []
        return (makeFunBind v (L (noAnnSrcSpan match_span)
                [L (noAnnSrcSpan match_span) (m (ApiAnn (realSrcSpan loc) annsIn cs) v)]))
  where
    m :: ApiAnn -> LocatedN RdrName -> Match GhcPs (LHsExpr GhcPs) -- AZ Temp
    m a v = Match { m_ext = a
                  -- AZ:TODO: probably need to chase this ann through somehow
                  , m_ctxt = FunRhs { mc_fun    = v
                                    , mc_fixity = Prefix
                                    , mc_strictness = SrcStrict }
                  , m_pats = []
                  , m_grhss = grhss }

checkPatBind loc annsIn lhs (L _ grhss) = do
  cs <- addAnnsAt loc []
  return (PatBind (ApiAnn (realSrcSpan loc) annsIn cs) lhs grhss ([],[]))

checkValSigLhs :: LHsExpr GhcPs -> P (LocatedN RdrName)
checkValSigLhs (L _ (HsVar _ lrdr@(L _ v)))
  | isUnqual v
  , not (isDataOcc (rdrNameOcc v))
  = return lrdr

checkValSigLhs lhs@(L l _)
  = addFatalError (locA l) ((text "Invalid type signature:" <+>
                             ppr lhs <+> text ":: ...")
                             $$ text hint)
  where
    hint | foreign_RDR `looks_like` lhs
         = "Perhaps you meant to use ForeignFunctionInterface?"
         | default_RDR `looks_like` lhs
         = "Perhaps you meant to use DefaultSignatures?"
         | pattern_RDR `looks_like` lhs
         = "Perhaps you meant to use PatternSynonyms?"
         | otherwise
         = "Should be of form <variable> :: <type>"

    -- A common error is to forget the ForeignFunctionInterface flag
    -- so check for that, and suggest.  cf #3805
    -- Sadly 'foreign import' still barfs 'parse error' because
    --  'import' is a keyword
    looks_like s (L _ (HsVar _ (L _ v))) = v == s
    looks_like s (L _ (HsApp _ lhs _))   = looks_like s lhs
    looks_like _ _                       = False

    foreign_RDR = mkUnqual varName (fsLit "foreign")
    default_RDR = mkUnqual varName (fsLit "default")
    pattern_RDR = mkUnqual varName (fsLit "pattern")

checkDoAndIfThenElse
  :: (Outputable a, Outputable b, Outputable c)
  => LocatedA a -> Bool -> b -> Bool -> LocatedA c -> PV ()
checkDoAndIfThenElse guardExpr semiThen thenExpr semiElse elseExpr
 | semiThen || semiElse
    = do doAndIfThenElse <- getBit DoAndIfThenElseBit
         unless doAndIfThenElse $ do
             addError (locA $ combineLocsA guardExpr elseExpr)
                            (text "Unexpected semi-colons in conditional:"
                          $$ nest 4 expr
                          $$ text "Perhaps you meant to use DoAndIfThenElse?")
 | otherwise            = return ()
    where pprOptSemi True  = semi
          pprOptSemi False = empty
          expr = text "if"   <+> ppr guardExpr <> pprOptSemi semiThen <+>
                 text "then" <+> ppr thenExpr  <> pprOptSemi semiElse <+>
                 text "else" <+> ppr elseExpr

isFunLhs :: LocatedA (PatBuilder GhcPs)
      -> P (Maybe (LocatedN RdrName, LexicalFixity,
                   [LocatedA (PatBuilder GhcPs)],[AddApiAnn]))
-- A variable binding is parsed as a FunBind.
-- Just (fun, is_infix, arg_pats) if e is a function LHS
isFunLhs e = go e [] []
 where
   go :: LocatedA (PatBuilder p)
      -> [LocatedA (PatBuilder p)]
      -> [AddApiAnn]
      -> P (Maybe
              (LocatedN RdrName, LexicalFixity,
               [LocatedA (PatBuilder p)], [AddApiAnn])) -- AZ temp
   go (L _ (PatBuilderVar (L loc f))) es ann
       | not (isRdrDataCon f)        = return (Just (L loc f, Prefix, es, ann))
   go (L _ (PatBuilderApp f e)) es       ann = go f (e:es) ann
   go (L l (PatBuilderPar e an))   es@(_:_) ann
                                      = go e es (ann ++ mkParensApiAnn (locA l))
   go (L loc (PatBuilderOpApp l (L loc' op) r (ApiAnn loca anns cs))) es ann
        | not (isRdrDataCon op)         -- We have found the function!
        = return (Just (L loc' op, Infix, (l:r:es), (anns ++ ann)))
        | otherwise                     -- Infix data con; keep going
        = do { mb_l <- go l es ann
             ; case mb_l of
                 Just (op', Infix, j : k : es', ann')
                   -> return (Just (op', Infix, j : op_app : es', ann'))
                   where
                     op_app = L loc (PatBuilderOpApp k
                               (L loc' op) r (ApiAnn loca anns cs))
                 _ -> return Nothing }
   go _ _ _ = return Nothing

-- | Either an operator or an operand.
data TyEl = TyElOpr (LocatedN RdrName) | TyElOpd (HsType GhcPs)
          | TyElKindApp SrcSpan (LHsType GhcPs)
          -- See Note [TyElKindApp SrcSpan interpretation]
          | TyElUnpackedness ([AddApiAnn], SourceText, SrcUnpackedness)
          | TyElDocPrev HsDocString


{- Note [TyElKindApp SrcSpan interpretation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A TyElKindApp captures type application written in haskell as

    @ Foo

where Foo is some type.

The SrcSpan reflects both elements, and there are AnnAt and AnnVal API
Annotations attached to this SrcSpan for the specific locations of
each within it.
-}

instance Outputable TyEl where
  ppr (TyElOpr name) = ppr name
  ppr (TyElOpd ty) = ppr ty
  ppr (TyElKindApp _ ki) = text "@" <> ppr ki
  ppr (TyElUnpackedness (_, _, unpk)) = ppr unpk
  ppr (TyElDocPrev doc) = ppr doc

-- | Extract a strictness/unpackedness annotation from the front of a reversed
-- 'TyEl' list.
pUnpackedness
  :: [LocatedA TyEl] -- reversed TyEl
  -> Maybe ( SrcSpanAnnA
           , [AddApiAnn]
           , SourceText
           , SrcUnpackedness
           , [LocatedA TyEl] {- remaining TyEl -})
pUnpackedness (L l x1 : xs)
  | TyElUnpackedness (anns, prag, unpk) <- x1
  = Just (l, anns, prag, unpk, xs)
pUnpackedness _ = Nothing

pBangTy
  :: LHsType GhcPs   -- a type to be wrapped inside HsBangTy
  -> [LocatedA TyEl] -- reversed TyEl
  -> ( Bool             -- has a strict mark been consumed?
     , LHsType GhcPs    -- the resulting BangTy
     , P ApiAnnComments -- add annotations
     , [LocatedA TyEl]) -- remaining TyEl
pBangTy lt@(L l1 _) xs =
  case pUnpackedness xs of
    Nothing -> (False, lt, pure [], xs)
    Just (l2, anns, prag, unpk, xs') ->
      let bl = combineSrcSpansA l1 l2
          bt = addUnpackedness (prag, unpk) lt
      in (True, L bl bt, addAnnsAt (locA bl) anns, xs')

mkBangTy :: ApiAnn -> SrcStrictness -> LHsType GhcPs -> HsType GhcPs
mkBangTy anns strictness =
  HsBangTy anns (HsSrcBang NoSourceText NoSrcUnpack strictness)

addUnpackedness :: (SourceText, SrcUnpackedness) -> LHsType GhcPs -> HsType GhcPs
addUnpackedness (prag, unpk) (L _ (HsBangTy x bang t))
  | HsSrcBang NoSourceText NoSrcUnpack strictness <- bang
  = HsBangTy x (HsSrcBang prag unpk strictness) t
addUnpackedness (prag, unpk) t
  -- AZ: TODO the noAnn should be actual anns
  = HsBangTy noAnn (HsSrcBang prag unpk NoSrcStrict) t

-- | Merge a /reversed/ and /non-empty/ soup of operators and operands
--   into a type.
--
-- User input: @F x y + G a b * X@
-- Input to 'mergeOps': [X, *, b, a, G, +, y, x, F]
-- Output corresponds to what the user wrote assuming all operators are of the
-- same fixity and right-associative.
--
-- It's a bit silly that we're doing it at all, as the renamer will have to
-- rearrange this, and it'd be easier to keep things separate.
--
-- See Note [Parsing data constructors is hard]
mergeOps :: [LocatedA TyEl] -> P (LHsType GhcPs)
mergeOps ((L l1 (TyElOpd t)) : xs)
  | (_, t', addAnns, xs') <- pBangTy (L l1 t) xs
  , null xs' -- We accept a BangTy only when there are no preceding TyEl.
  = addAnns >> return t'
mergeOps all_xs = go (0 :: Int) [] id all_xs
  where
    -- NB. When modifying clauses in 'go', make sure that the reasoning in
    -- Note [Non-empty 'acc' in mergeOps clause [end]] is still correct.

    -- clause [unpk]:
    -- handle (NO)UNPACK pragmas
    go :: Int
       -> [HsArg (LHsType GhcPs) (LHsKind GhcPs)]
       -> (LHsType GhcPs -> LHsType GhcPs)
       -> [LocatedA TyEl]
       -> P (LHsType GhcPs) -- AZ temp
    go k acc ops_acc ((L l (TyElUnpackedness (anns, unpkSrc, unpk))):xs) =
      if not (null acc) && null xs
      then do { acc' <- eitherToP $ mergeOpsAcc acc
              ; let a = ops_acc acc'
                    strictMark = HsSrcBang unpkSrc unpk NoSrcStrict
                    bl = combineSrcSpansA l (getLoc a)
                    bt = HsBangTy noAnn strictMark a -- AZ:TODO anns
              -- AZ:TODO: deal with the comments below
              ; _cs <- addAnnsAt (locA bl) anns
              ; return (L bl bt) }
      else addFatalError (locA l) unpkError
      where
        unpkSDoc = case unpkSrc of
          NoSourceText -> ppr unpk
          SourceText str -> text str <> text " #-}"
        unpkError
          | not (null xs) = unpkSDoc <+> text "cannot appear inside a type."
          | null acc && k == 0 = unpkSDoc <+> text "must be applied to a type."
          | otherwise =
              -- See Note [Impossible case in mergeOps clause [unpk]]
              panic "mergeOps.UNPACK: impossible position"

    -- clause [doc]:
    -- we do not expect to encounter any docs
    go _ _ _ ((L l (TyElDocPrev _)):_) =
      failOpDocPrev (locA l)

    -- clause [opr]:
    -- when we encounter an operator, we must have accumulated
    -- something for its rhs, and there must be something left
    -- to build its lhs.
    go k acc ops_acc ((L _ (TyElOpr op)):xs) =
      if null acc || null (filter isTyElOpd xs)
        then failOpFewArgs op
        else do { acc' <- eitherToP (mergeOpsAcc acc)
                ; go (k + 1) [] (\c -> mkLHsOpTy c op (ops_acc acc')) xs }
      where
        isTyElOpd (L _ (TyElOpd _)) = True
        isTyElOpd _ = False

    -- clause [opd]:
    -- whenever an operand is encountered, it is added to the accumulator
    go k acc ops_acc ((L l (TyElOpd a)):xs)
      = go k (HsValArg (L l a):acc) ops_acc xs

    -- clause [tyapp]:
    -- whenever a type application is encountered, it is added to the accumulator
    go k acc ops_acc ((L _ (TyElKindApp l a)):xs) = go k (HsTypeArg l a:acc) ops_acc xs

    -- clause [end]
    -- See Note [Non-empty 'acc' in mergeOps clause [end]]
    go _ acc ops_acc [] = do { acc' <- eitherToP (mergeOpsAcc acc)
                             ; return (ops_acc acc') }

mergeOpsAcc :: [HsArg (LHsType GhcPs) (LHsKind GhcPs)]
         -> Either (SrcSpan, SDoc) (LHsType GhcPs)
mergeOpsAcc [] = panic "mergeOpsAcc: empty input"
mergeOpsAcc (HsTypeArg _ (L loc ki):_)
  = Left (locA loc, text "Unexpected type application:" <+> ppr ki)
mergeOpsAcc (HsValArg ty : xs) = go1 ty xs
  where
    go1 :: LHsType GhcPs
        -> [HsArg (LHsType GhcPs) (LHsKind GhcPs)]
        -> Either (SrcSpan, SDoc) (LHsType GhcPs)
    go1 lhs []     = Right lhs
    go1 lhs (x:xs) = case x of
        HsValArg ty -> go1 (mkHsAppTy lhs ty) xs
        HsTypeArg loc ki -> let ty = mkHsAppKindTy loc lhs ki
                            in go1 ty xs
        HsArgPar _ -> go1 lhs xs
mergeOpsAcc (HsArgPar _: xs) = mergeOpsAcc xs

{- Note [Impossible case in mergeOps clause [unpk]]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
This case should never occur. Let us consider all possible
variations of 'acc', 'xs', and 'k':

  acc          xs        k
==============================
  null   |    null       0      -- "must be applied to a type"
  null   |  not null     0      -- "must be applied to a type"
not null |    null       0      -- successful parse
not null |  not null     0      -- "cannot appear inside a type"
  null   |    null      >0      -- handled in clause [opr]
  null   |  not null    >0      -- "cannot appear inside a type"
not null |    null      >0      -- successful parse
not null |  not null    >0      -- "cannot appear inside a type"

The (null acc && null xs && k>0) case is handled in clause [opr]
by the following check:

    if ... || null (filter isTyElOpd xs)
     then failOpFewArgs (L l op)

We know that this check has been performed because k>0, and by
the time we reach the end of the list (null xs), the only way
for (null acc) to hold is that there was not a single TyElOpd
between the operator and the end of the list. But this case is
caught by the check and reported as 'failOpFewArgs'.
-}

{- Note [Non-empty 'acc' in mergeOps clause [end]]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In clause [end] we need to know that 'acc' is non-empty to call 'mergeAcc'
without a check.

Running 'mergeOps' with an empty input list is forbidden, so we do not consider
this possibility. This means we'll hit at least one other clause before we
reach clause [end].

* Clauses [unpk] and [doc] do not call 'go' recursively, so we cannot hit
  clause [end] from there.
* Clause [opd] makes 'acc' non-empty, so if we hit clause [end] after it, 'acc'
  will be non-empty.
* Clause [opr] checks that (filter isTyElOpd xs) is not null - so we are going
  to hit clause [opd] at least once before we reach clause [end], making 'acc'
  non-empty.
* There are no other clauses.

Therefore, it is safe to omit a check for non-emptiness of 'acc' in clause
[end].

-}

pInfixSide
  :: [LocatedA TyEl] -> Maybe (LHsType GhcPs, P ApiAnnComments, [LocatedA TyEl])
pInfixSide ((L l (TyElOpd t)):xs)
  | (True, t', addAnns, xs') <- pBangTy (L l t) xs
  = Just (t', addAnns, xs')
pInfixSide (el:xs1)
  | Just t1 <- pLHsTypeArg el
  = go [t1] xs1
   where
     go :: [HsArg (LHsType GhcPs) (LHsKind GhcPs)]
        -> [LocatedA TyEl]
        -> Maybe (LHsType GhcPs, P ApiAnnComments, [LocatedA TyEl])
     go acc (el:xs)
       | Just t <- pLHsTypeArg el
       = go (t:acc) xs
     go acc xs = case mergeOpsAcc acc of
       Left _ -> Nothing
       Right acc' -> Just (acc', pure [], xs)
pInfixSide _ = Nothing

pLHsTypeArg :: LocatedA TyEl -> Maybe (HsArg (LHsType GhcPs) (LHsKind GhcPs))
pLHsTypeArg (L l (TyElOpd a)) = Just (HsValArg (L l a))
pLHsTypeArg (L _ (TyElKindApp l a)) = Just (HsTypeArg l a)
pLHsTypeArg _ = Nothing

pDocPrev :: [LocatedA TyEl] -> (Maybe LHsDocString, [LocatedA TyEl])
pDocPrev = go Nothing
  where
    go mTrailingDoc ((L l (TyElDocPrev doc)):xs) =
      go (mTrailingDoc `mplus` Just (L (locA l) doc)) xs
    go mTrailingDoc xs = (mTrailingDoc, xs)

orErr :: Maybe a -> b -> Either b a
orErr (Just a) _ = Right a
orErr Nothing b = Left b

-- | Merge a /reversed/ and /non-empty/ soup of operators and operands
--   into a data constructor.
--
-- User input: @C !A B -- ^ doc@
-- Input to 'mergeDataCon': ["doc", B, !A, C]
-- Output: (C, PrefixCon [!A, B], "doc")
--
-- See Note [Parsing data constructors is hard]
mergeDataCon
      :: [LocatedA TyEl]
      -> P ( LocatedN RdrName        -- constructor name
           , HsConDeclDetails GhcPs  -- constructor field information
           , Maybe LHsDocString      -- docstring to go on the constructor
           )
mergeDataCon all_xs =
  do { (addAnns, a) <- eitherToP res
     -- AZ:TODO: deal with these comments
     ; _cs <- addAnns
     ; return a }
  where
    -- We start by splitting off the trailing documentation comment,
    -- if any exists.
    (mTrailingDoc, all_xs') = pDocPrev all_xs

    -- Determine whether the trailing documentation comment exists and is the
    -- only docstring in this constructor declaration.
    --
    -- When true, it means that it applies to the constructor itself:
    --    data T = C
    --             A
    --             B -- ^ Comment on C (singleDoc == True)
    --
    -- When false, it means that it applies to the last field:
    --    data T = C -- ^ Comment on C
    --             A -- ^ Comment on A
    --             B -- ^ Comment on B (singleDoc == False)
    singleDoc = isJust mTrailingDoc &&
                null [ () | (L _ (TyElDocPrev _)) <- all_xs' ]

    -- The result of merging the list of reversed TyEl into a
    -- data constructor, along with [AddApiAnn].
    res :: Either (SrcSpan, SDoc)
                        (P ApiAnnComments,
                         (LocatedN RdrName,
                          HsConDeclDetails GhcPs,
                          Maybe LHsDocString)) -- AZ temp
    res = goFirst all_xs'

    -- Take the trailing docstring into account when interpreting
    -- the docstring near the constructor.
    --
    --    data T = C -- ^ docstring right after C
    --             A
    --             B -- ^ trailing docstring
    --
    -- 'mkConDoc' must be applied to the docstring right after C, so that it
    -- falls back to the trailing docstring when appropriate (see singleDoc).
    mkConDoc mDoc | singleDoc = mDoc `mplus` mTrailingDoc
                  | otherwise = mDoc

    -- The docstring for the last field of a data constructor.
    trailingFieldDoc | singleDoc = Nothing
                     | otherwise = mTrailingDoc

    goFirst :: [LocatedA TyEl]
            -> Either
                 (SrcSpan, SDoc)
                 (P ApiAnnComments,
                  (LocatedN RdrName,
                   HsConDeclDetails GhcPs,
                   Maybe LHsDocString)) -- AZ temp
    goFirst [ L _ (TyElOpd (HsTyVar _ _ tc)) ]
      = do { data_con <- tyConToDataCon tc
           ; return (pure [], (data_con, PrefixCon [], mTrailingDoc)) }
    goFirst ((L l (TyElOpd (HsRecTy an fields))):xs)
      | (mConDoc, xs') <- pDocPrev xs
      , [ L _ (TyElOpd (HsTyVar _ _ tc)) ] <- xs'
      = do { data_con <- tyConToDataCon tc
           ; let mDoc = mTrailingDoc `mplus` mConDoc
           ; return (pure [], (data_con, RecCon (L (SrcSpanAnn an (locA l)) fields), mDoc)) }
    goFirst [L l (TyElOpd (HsTupleTy _ HsBoxedOrConstraintTuple ts))]
      = return ( pure []
               , ( L (l2l l) (getRdrName (tupleDataCon Boxed (length ts)))
                 , PrefixCon (map hsLinear ts)
                 , mTrailingDoc ) )
    goFirst ((L l (TyElOpd t)):xs)
      | (_, t', addAnns, xs') <- pBangTy (L l t) xs
      = go addAnns Nothing [mkLHsDocTyMaybe t' trailingFieldDoc] xs'
    goFirst (L l (TyElKindApp _ _):_)
      = goInfix Monoid.<> Left (locA l, kindAppErr)
    goFirst xs
      = go (pure []) mTrailingDoc [] xs

    go :: P ApiAnnComments
                   -> Maybe LHsDocString
                   -> [LHsType GhcPs]
                   -> [LocatedA TyEl]
                   -> Either
                        (SrcSpan, SDoc)
                        (P ApiAnnComments,
                         (LocatedN RdrName,
                          HsConDeclDetails GhcPs,
                          Maybe LHsDocString)) -- AZ
    go addAnns mLastDoc ts [ L l (TyElOpd (HsTyVar _ _ tc)) ]
      = do { data_con <- tyConToDataCon tc
           ; return (addAnns, (data_con, PrefixCon (map hsLinear ts), mkConDoc mLastDoc)) }
    go addAnns mLastDoc ts ((L l (TyElDocPrev doc)):xs) =
      go addAnns (mLastDoc `mplus` Just (L (locA l) doc)) ts xs
    go addAnns mLastDoc ts ((L l (TyElOpd t)):xs)
      | (_, t', addAnns', xs') <- pBangTy (L l t) xs
      , t'' <- mkLHsDocTyMaybe t' mLastDoc
      = go (addAnns >> addAnns') Nothing (t'':ts) xs'
    go _ _ _ ((L _ (TyElOpr _)):_) =
      -- Encountered an operator: backtrack to the beginning and attempt
      -- to parse as an infix definition.
      goInfix
    go _ _ _ (L l (TyElKindApp _ _):_)
                                  =  goInfix Monoid.<> Left (locA l, kindAppErr)
    go _ _ _ _ = Left malformedErr
      where
        malformedErr =
          ( foldr combineSrcSpans noSrcSpan (map getLocA all_xs')
          , text "Cannot parse data constructor" <+>
            text "in a data/newtype declaration:" $$
            nest 2 (hsep . reverse $ map ppr all_xs'))

    goInfix :: Either
                 (SrcSpan, SDoc)
                 (P ApiAnnComments,
                  (LocatedN RdrName, HsConDeclDetails GhcPs,
                   Maybe LHsDocString))  --AZ Temp
    goInfix =
      do { let xs0 = all_xs'
         ; (rhs_t, rhs_addAnns, xs1) <- pInfixSide xs0 `orErr` malformedErr
         ; let (mOpDoc, xs2) = pDocPrev xs1
         ; (op, xs3) <- case xs2 of
              (L _ (TyElOpr op)) : xs3 ->
                do { data_con <- tyConToDataCon op
                   ; return (data_con, xs3) }
              _ -> Left malformedErr
         ; let (mLhsDoc, xs4) = pDocPrev xs3
         ; (lhs_t, lhs_addAnns, xs5) <- pInfixSide xs4 `orErr` malformedErr
         ; unless (null xs5) (Left malformedErr)
         ; let rhs = mkLHsDocTyMaybe rhs_t trailingFieldDoc
               lhs = mkLHsDocTyMaybe lhs_t mLhsDoc
               addAnns = lhs_addAnns >> rhs_addAnns
         ; return (addAnns, (op, InfixCon (hsLinear lhs) (hsLinear rhs), mkConDoc mOpDoc)) }
      where
        malformedErr =
          ( foldr combineSrcSpans noSrcSpan (map getLocA all_xs')
          , text "Cannot parse an infix data constructor" <+>
            text "in a data/newtype declaration:" $$
            nest 2 (hsep . reverse $ map ppr all_xs'))

    kindAppErr =
      text "Unexpected kind application" <+>
      text "in a data/newtype declaration:" $$
      nest 2 (hsep . reverse $ map ppr all_xs')

---------------------------------------------------------------------------
-- | Check for monad comprehensions
--
-- If the flag MonadComprehensions is set, return a 'MonadComp' context,
-- otherwise use the usual 'ListComp' context

checkMonadComp :: PV (HsStmtContext Name)
checkMonadComp = do
    monadComprehensions <- getBit MonadComprehensionsBit
    return $ if monadComprehensions
                then MonadComp
                else ListComp

-- -------------------------------------------------------------------------
-- Expression/command/pattern ambiguity.
-- See Note [Ambiguous syntactic categories]
--

-- See Note [Parser-Validator]
-- See Note [Ambiguous syntactic categories]
--
-- This newtype is required to avoid impredicative types in monadic
-- productions. That is, in a production that looks like
--
--    | ... {% return (ECP ...) }
--
-- we are dealing with
--    P ECP
-- whereas without a newtype we would be dealing with
--    P (forall b. DisambECP b => PV (Located b))
--
newtype ECP =
  -- TODO:AZ return value may better be PV (Located b)
  ECP { runECP_PV :: forall b. DisambECP b => PV (LocatedA b) }

runECP_P :: DisambECP b => ECP -> P (LocatedA b)
runECP_P p = runPV (runECP_PV p)

ecpFromExp :: LHsExpr GhcPs -> ECP
ecpFromExp a = ECP (ecpFromExp' a)

ecpFromCmd :: LHsCmd GhcPs -> ECP
ecpFromCmd a = ECP (ecpFromCmd' a)

-- | Disambiguate infix operators.
-- See Note [Ambiguous syntactic categories]
class DisambInfixOp b where
  mkHsVarOpPV :: LocatedN RdrName -> PV (LocatedN b)
  mkHsConOpPV :: LocatedN RdrName -> PV (LocatedN b)
  mkHsInfixHolePV :: SrcSpan -> [AddApiAnn] -> PV (Located b)

instance DisambInfixOp (HsExpr GhcPs) where
  mkHsVarOpPV v = return $ L (getLoc v) (HsVar noExtField v)
  mkHsConOpPV v = return $ L (getLoc v) (HsVar noExtField v)
  mkHsInfixHolePV l ann = do
    cs <- addAnnsAt l []
    return $ L l (hsHoleExpr (ApiAnn (realSrcSpan l) ann cs))

instance DisambInfixOp RdrName where
  mkHsConOpPV (L l v) = return $ L l v
  mkHsVarOpPV (L l v) = return $ L l v
  mkHsInfixHolePV l _ =
    addFatalError l $ text "Invalid infix hole, expected an infix operator"

-- | Disambiguate constructs that may appear when we do not know ahead of time whether we are
-- parsing an expression, a command, or a pattern.
-- See Note [Ambiguous syntactic categories]
class b ~ (Body b) GhcPs => DisambECP b where
  -- | See Note [Body in DisambECP]
  type Body b :: Type -> Type
  -- | Return a command without ambiguity, or fail in a non-command context.
  ecpFromCmd' :: LHsCmd GhcPs -> PV (LocatedA b)
  -- | Return an expression without ambiguity, or fail in a non-expression context.
  ecpFromExp' :: LHsExpr GhcPs -> PV (LocatedA b)
  -- | Disambiguate "\... -> ..." (lambda)
  mkHsLamPV
    :: SrcSpan -> (ApiAnnComments -> MatchGroup GhcPs (LocatedA b)) -> PV (LocatedA b)
  -- | Disambiguate "let ... in ..."
  mkHsLetPV
    :: SrcSpan -> LHsLocalBinds GhcPs -> LocatedA b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Infix operator representation
  type InfixOp b
  -- | Bring superclass constraints on InfixOp into scope.
  -- See Note [UndecidableSuperClasses for associated types]
  superInfixOp
    :: (DisambInfixOp (InfixOp b) => PV (LocatedA b )) -> PV (LocatedA b)
  -- | Disambiguate "f # x" (infix operator)
  mkHsOpAppPV :: SrcSpan -> LocatedA b -> LocatedN (InfixOp b) -> LocatedA b
              -> PV (LocatedA b)
  -- | Disambiguate "case ... of ..."
  mkHsCasePV :: SrcSpan -> LHsExpr GhcPs -> (LocatedL [LMatch GhcPs (LocatedA b)])
             -> ApiAnnHsCase -> PV (LocatedA b)
  mkHsLamCasePV :: SrcSpan -> (LocatedL [LMatch GhcPs (LocatedA b)])
                -> [AddApiAnn]
                -> PV (LocatedA b)
  -- | Function argument representation
  type FunArg b
  -- | Bring superclass constraints on FunArg into scope.
  -- See Note [UndecidableSuperClasses for associated types]
  superFunArg :: (DisambECP (FunArg b) => PV (LocatedA b)) -> PV (LocatedA b)
  -- | Disambiguate "f x" (function application)
  mkHsAppPV :: SrcSpanAnnA -> LocatedA b -> LocatedA (FunArg b) -> PV (LocatedA b)
  -- | Disambiguate "f @t" (visible type application)
  mkHsAppTypePV :: SrcSpanAnnA -> LocatedA b -> LHsType GhcPs -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate "if ... then ... else ..."
  mkHsIfPV :: SrcSpan
         -> LHsExpr GhcPs
         -> Bool  -- semicolon?
         -> LocatedA b
         -> Bool  -- semicolon?
         -> LocatedA b
         -> [AddApiAnn]
         -> PV (LocatedA b)
  -- | Disambiguate "do { ... }" (do notation)
  mkHsDoPV ::
    SrcSpan ->
    Maybe ModuleName ->
    LocatedL [LStmt GhcPs (LocatedA b)] ->
    AnnList ->
    PV (LocatedA b)
  -- | Disambiguate "( ... )" (parentheses)
  mkHsParPV :: SrcSpan -> LocatedA b -> AnnParen -> PV (LocatedA b)
  -- | Disambiguate a variable "f" or a data constructor "MkF".
  mkHsVarPV :: LocatedN RdrName -> PV (LocatedA b)
  -- | Disambiguate a monomorphic literal
  mkHsLitPV :: Located (HsLit GhcPs) -> PV (Located b)
  -- | Disambiguate an overloaded literal
  mkHsOverLitPV :: Located (HsOverLit GhcPs) -> PV (Located b)
  -- | Disambiguate a wildcard
  mkHsWildCardPV :: SrcSpan -> PV (Located b)
  -- | Disambiguate "a :: t" (type annotation)
  mkHsTySigPV
    :: SrcSpanAnnA -> LocatedA b -> LHsType GhcPs -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate "[a,b,c]" (list syntax)
  mkHsExplicitListPV :: SrcSpan -> [LocatedA b] -> AnnList -> PV (LocatedA b)
  -- | Disambiguate "$(...)" and "[quasi|...|]" (TH splices)
  mkHsSplicePV :: Located (HsSplice GhcPs) -> PV (Located b)
  -- | Disambiguate "f { a = b, ... }" syntax (record construction and record updates)
  mkHsRecordPV ::
    SrcSpan ->
    SrcSpan ->
    LocatedA b ->
    ([LHsRecField GhcPs (LocatedA b)], Maybe SrcSpan) ->
    [AddApiAnn] ->
    PV (LocatedA b)
  -- | Disambiguate "-a" (negation)
  mkHsNegAppPV :: SrcSpan -> LocatedA b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate "(# a)" (right operator section)
  mkHsSectionR_PV
    :: SrcSpan -> LocatedA (InfixOp b) -> LocatedA b -> PV (Located b)
  -- | Disambiguate "(a -> b)" (view pattern)
  mkHsViewPatPV
    :: SrcSpan -> LHsExpr GhcPs -> LocatedA b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate "a@b" (as-pattern)
  mkHsAsPatPV
    :: SrcSpan -> LocatedN RdrName -> LocatedA b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate "~a" (lazy pattern)
  mkHsLazyPatPV :: SrcSpan -> Located b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate "!a" (bang pattern)
  mkHsBangPatPV :: SrcSpan -> Located b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Disambiguate tuple sections and unboxed sums
  mkSumOrTuplePV
    :: SrcSpanAnnA -> Boxity -> SumOrTuple b -> [AddApiAnn] -> PV (LocatedA b)
  -- | Validate infixexp LHS to reject unwanted {-# SCC ... #-} pragmas
  rejectPragmaPV :: LocatedA b -> PV ()


{- Note [UndecidableSuperClasses for associated types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(This Note is about the code in GHC, not about the user code that we are parsing)

Assume we have a class C with an associated type T:

  class C a where
    type T a
    ...

If we want to add 'C (T a)' as a superclass, we need -XUndecidableSuperClasses:

  {-# LANGUAGE UndecidableSuperClasses #-}
  class C (T a) => C a where
    type T a
    ...

Unfortunately, -XUndecidableSuperClasses don't work all that well, sometimes
making GHC loop. The workaround is to bring this constraint into scope
manually with a helper method:

  class C a where
    type T a
    superT :: (C (T a) => r) -> r

In order to avoid ambiguous types, 'r' must mention 'a'.

For consistency, we use this approach for all constraints on associated types,
even when -XUndecidableSuperClasses are not required.
-}

{- Note [Body in DisambECP]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
There are helper functions (mkBodyStmt, mkBindStmt, unguardedRHS, etc) that
require their argument to take a form of (body GhcPs) for some (body :: Type ->
*). To satisfy this requirement, we say that (b ~ Body b GhcPs) in the
superclass constraints of DisambECP.

The alternative is to change mkBodyStmt, mkBindStmt, unguardedRHS, etc, to drop
this requirement. It is possible and would allow removing the type index of
PatBuilder, but leads to worse type inference, breaking some code in the
typechecker.
-}

instance DisambECP (HsCmd GhcPs) where
  type Body (HsCmd GhcPs) = HsCmd
  ecpFromCmd' = return
  ecpFromExp' (L l e) = cmdFail (locA l) (ppr e)
  mkHsLamPV l mg = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsCmdLam NoExtField (mg cs))
  mkHsLetPV l bs e anns = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsCmdLet (ApiAnn (realSrcSpan l) anns cs) bs e)
  type InfixOp (HsCmd GhcPs) = HsExpr GhcPs
  superInfixOp m = m
  mkHsOpAppPV l c1 op c2 = do
    let cmdArg c = L (getLocA c) $ HsCmdTop noExtField c
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) $ HsCmdArrForm (ApiAnn (realSrcSpan l) (AnnList Nothing Nothing [] []) cs) (reLocL op) Infix Nothing [cmdArg c1, cmdArg c2]
  mkHsCasePV l c (L lm m) anns = do
    cs <- addAnnsAt l []
    let mg = mkMatchGroup FromSource (L lm m)
    return $ L (noAnnSrcSpan l) (HsCmdCase (ApiAnn (realSrcSpan l) anns cs) c mg)
  mkHsLamCasePV l (L lm m) anns = do
    cs <- addAnnsAt l []
    let mg = mkMatchGroup FromSource (L lm m)
    return $ L (noAnnSrcSpan l) (HsCmdLamCase (ApiAnn (realSrcSpan l) anns cs) mg)
  type FunArg (HsCmd GhcPs) = HsExpr GhcPs
  superFunArg m = m
  mkHsAppPV l c e = do
    cs <- addAnnsAt (locA l) []
    checkCmdBlockArguments c
    checkExpBlockArguments e
    return $ L l (HsCmdApp (comment (realSrcSpan $ locA l) cs) c e)
  mkHsAppTypePV l c t _ = cmdFail (locA l) (ppr c <+> text "@" <> ppr t)
  mkHsIfPV l c semi1 a semi2 b anns = do
    checkDoAndIfThenElse c semi1 a semi2 b
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (mkHsCmdIf c a b (ApiAnn (realSrcSpan l) anns cs))
  mkHsDoPV l Nothing stmts anns = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsCmdDo (ApiAnn (realSrcSpan l) anns cs) stmts)
  mkHsDoPV l (Just m)    _ _ =
    cmdFail l $
      text "Found a qualified" <+> ppr m <> text ".do block in a command, but"
      $$ text "qualified 'do' is not supported in commands."
  mkHsParPV l c ann = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsCmdPar (ApiAnn (realSrcSpan l) ann cs) c)
  mkHsVarPV (L l v) = cmdFail (locA l) (ppr v)
  mkHsLitPV (L l a) = cmdFail l (ppr a)
  mkHsOverLitPV (L l a) = cmdFail l (ppr a)
  mkHsWildCardPV l = cmdFail l (text "_")
  mkHsTySigPV l a sig _ = cmdFail (locA l) (ppr a <+> text "::" <+> ppr sig)
  mkHsExplicitListPV l xs _ = cmdFail l $
    brackets (fsep (punctuate comma (map ppr xs)))
  mkHsSplicePV (L l sp) = cmdFail l (ppr sp)
  mkHsRecordPV l _ a (fbinds, ddLoc) _ = cmdFail l $
    ppr a <+> ppr (mk_rec_fields fbinds ddLoc)
  mkHsNegAppPV l a _ = cmdFail l (text "-" <> ppr a)
  mkHsSectionR_PV l op c = cmdFail l $
    let pp_op = fromMaybe (panic "cannot print infix operator")
                          (ppr_infix_expr (unLoc op))
    in pp_op <> ppr c
  mkHsViewPatPV l a b _ = cmdFail l $
    ppr a <+> text "->" <+> ppr b
  mkHsAsPatPV l v c _ = cmdFail l $
    pprPrefixOcc (unLoc v) <> text "@" <> ppr c
  mkHsLazyPatPV l c _ = cmdFail l $
    text "~" <> ppr c
  mkHsBangPatPV l c _ = cmdFail l $
    text "!" <> ppr c
  mkSumOrTuplePV l boxity a _ = cmdFail (locA l) (pprSumOrTuple boxity a)
  rejectPragmaPV _ = return ()

cmdFail :: SrcSpan -> SDoc -> PV a
cmdFail loc e = addFatalError loc $
  hang (text "Parse error in command:") 2 (ppr e)

instance DisambECP (HsExpr GhcPs) where
  type Body (HsExpr GhcPs) = HsExpr
  ecpFromCmd' (L l c) = do
    addError (locA l) $ vcat
      [ text "Arrow command found where an expression was expected:",
        nest 2 (ppr c) ]
    return (L l (hsHoleExpr noAnn))
  ecpFromExp' = return
  mkHsLamPV l mg = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsLam NoExtField (mg cs))
  mkHsLetPV l bs c anns = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsLet (ApiAnn (realSrcSpan l) anns cs) bs c)
  type InfixOp (HsExpr GhcPs) = HsExpr GhcPs
  superInfixOp m = m
  mkHsOpAppPV l e1 op e2 = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) $ OpApp (ApiAnn (realSrcSpan l) [] cs) e1 (reLocL op) e2
  mkHsCasePV l e (L lm m) anns = do
    cs <- addAnnsAt l []
    let mg = mkMatchGroup FromSource (L lm m)
    return $ L (noAnnSrcSpan l) (HsCase (ApiAnn (realSrcSpan l) anns cs) e mg)
  mkHsLamCasePV l (L lm m) anns = do
    cs <- addAnnsAt l []
    let mg = mkMatchGroup FromSource (L lm m)
    return $ L (noAnnSrcSpan l) (HsLamCase (ApiAnn (realSrcSpan l) anns cs) mg)
  type FunArg (HsExpr GhcPs) = HsExpr GhcPs
  superFunArg m = m
  mkHsAppPV l e1 e2 = do
    cs <- addAnnsAt (locA l) []
    checkExpBlockArguments e1
    checkExpBlockArguments e2
    return $ L l (HsApp (comment (realSrcSpan $ locA l) cs) e1 e2)
  mkHsAppTypePV l e t anns = do
    checkExpBlockArguments e
    cs <- addAnnsAt (locA l) []
    return $ L l (HsAppType (ApiAnn (realSrcSpan $ locA l) anns cs) e (mkHsWildCardBndrs t))
  mkHsIfPV l c semi1 a semi2 b anns = do
    checkDoAndIfThenElse c semi1 a semi2 b
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (mkHsIf c a b (ApiAnn (realSrcSpan l) anns cs))
  mkHsDoPV l mod stmts anns = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsDo (ApiAnn (realSrcSpan l) anns cs) (DoExpr mod) stmts)
  mkHsParPV l e ann = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (HsPar (ApiAnn (realSrcSpan l) ann cs) e)
  mkHsVarPV v@(L l _) = return $ L (na2la l) (HsVar noExtField v)
  mkHsLitPV (L l a) = do
    cs <- addAnnsAt l []
    return $ L l (HsLit (comment (realSrcSpan l) cs) a)
  mkHsOverLitPV (L l a) = do
    cs <- addAnnsAt l []
    return $ L l (HsOverLit (comment (realSrcSpan l) cs) a)
  mkHsWildCardPV l = return $ L l (hsHoleExpr noAnn)
  mkHsTySigPV l a sig anns = do
    cs <- addAnnsAt (locA l) []
    return $ L l (ExprWithTySig (ApiAnn (realSrcSpan $ locA l) anns cs) a (mkLHsSigWcType sig))
  mkHsExplicitListPV l xs anns = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (ExplicitList (ApiAnn (realSrcSpan l) anns cs) Nothing xs)
  mkHsSplicePV sp@(L l _sp) = do
    cs <- addAnnsAt l []
    return $ mapLoc (HsSpliceE (ApiAnn (realSrcSpan l) NoApiAnns cs)) sp
  mkHsRecordPV l lrec a (fbinds, ddLoc) anns = do
    cs <- addAnnsAt l []
    r <- mkRecConstrOrUpdate a lrec (fbinds, ddLoc) (ApiAnn (realSrcSpan l) anns cs)
    checkRecordSyntax (L (noAnnSrcSpan l) r)
  mkHsNegAppPV l a anns = do
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (NegApp (ApiAnn (realSrcSpan l) anns cs) a noSyntaxExpr)
  mkHsSectionR_PV l op e = do
    cs <- addAnnsAt l []
    return $ L l (SectionR (comment (realSrcSpan l) cs) op e)
  mkHsViewPatPV l a b _
    = patSynErr "View pattern" l (ppr (reLoc a) <+> text "->" <+> ppr (reLoc b)) empty
  mkHsAsPatPV l v e _ =
    patSynErr "@-pattern" l (pprPrefixOcc (unLoc v) <> text "@" <> ppr e) $
    text "Type application syntax requires a space before '@'"
  mkHsLazyPatPV l e _ = patSynErr "Lazy pattern" l (text "~" <> ppr e) $
    text "Did you mean to add a space after the '~'?"
  mkHsBangPatPV l e _ = patSynErr "Bang pattern" l (text "!" <> ppr e) $
    text "Did you mean to add a space after the '!'?"
  mkSumOrTuplePV = mkSumOrTupleExpr
  rejectPragmaPV (L _ (OpApp _ _ _ e)) =
    -- assuming left-associative parsing of operators
    rejectPragmaPV e
  rejectPragmaPV (L l (HsPragE _ prag _)) =
    addError (locA l) $
      hang (text "A pragma is not allowed in this position:") 2 (ppr prag)
  rejectPragmaPV _ = return ()

patSynErr :: String -> SrcSpan -> SDoc -> SDoc -> PV (LHsExpr GhcPs)
patSynErr item l e explanation =
  do { addError l $
        sep [text item <+> text "in expression context:",
             nest 4 (ppr e)] $$
        explanation
     ; return (L (noAnnSrcSpan l) (hsHoleExpr noAnn)) }

hsHoleExpr :: ApiAnn -> HsExpr GhcPs
hsHoleExpr anns = HsUnboundVar anns (mkVarOcc "_")

-- | See Note [Ambiguous syntactic categories] and Note [PatBuilder]
data PatBuilder p
  = PatBuilderPat (Pat p)
  | PatBuilderPar (LocatedA (PatBuilder p)) AnnParen
  | PatBuilderApp (LocatedA (PatBuilder p)) (LocatedA (PatBuilder p))
  | PatBuilderOpApp (LocatedA (PatBuilder p)) (LocatedN RdrName)
                    (LocatedA (PatBuilder p)) ApiAnn
  | PatBuilderVar (LocatedN RdrName)
  | PatBuilderOverLit (HsOverLit GhcPs)

instance Outputable (PatBuilder GhcPs) where
  ppr (PatBuilderPat p) = ppr p
  ppr (PatBuilderPar (L _ p) _) = parens (ppr p)
  ppr (PatBuilderApp (L _ p1) (L _ p2)) = ppr p1 <+> ppr p2
  ppr (PatBuilderOpApp (L _ p1) op (L _ p2) _) = ppr p1 <+> ppr op <+> ppr p2
  ppr (PatBuilderVar v) = ppr v
  ppr (PatBuilderOverLit l) = ppr l

instance DisambECP (PatBuilder GhcPs) where
  type Body (PatBuilder GhcPs) = PatBuilder
  ecpFromCmd' (L l c) =
    addFatalError (locA l) $
      text "Command syntax in pattern:" <+> ppr c
  ecpFromExp' (L l e) =
    addFatalError (locA l) $
      text "Expression syntax in pattern:" <+> ppr e
  mkHsLamPV l _ = addFatalError l $
    text "Lambda-syntax in pattern." $$
    text "Pattern matching on functions is not possible."
  mkHsLetPV l _ _ _
    = addFatalError l $ text "(let ... in ...)-syntax in pattern"
  type InfixOp (PatBuilder GhcPs) = RdrName
  superInfixOp m = m
  mkHsOpAppPV l p1 op p2 = do
    cs <- addAnnsAt l []
    let anns = ApiAnn (realSrcSpan l) [] cs
    return $ L (noAnnSrcSpan l) $ PatBuilderOpApp p1 op p2 anns
  mkHsCasePV l _ _ _
    = addFatalError l $ text "(case ... of ...)-syntax in pattern"
  mkHsLamCasePV l _ _ = addFatalError l $ text "(\\case ...)-syntax in pattern"
  type FunArg (PatBuilder GhcPs) = PatBuilder GhcPs
  superFunArg m = m
  mkHsAppPV l p1 p2 = return $ L l (PatBuilderApp p1 p2)
  mkHsAppTypePV l _ _ _ = addFatalError (locA l) $
    text "Type applications in patterns are not yet supported"
  mkHsIfPV l _ _ _ _ _ _ = addFatalError l $ text "(if ... then ... else ...)-syntax in pattern"
  mkHsDoPV l _ _ _ = addFatalError l $ text "do-notation in pattern"
  mkHsParPV l p an = return $ L (noAnnSrcSpan l) (PatBuilderPar p an)
  mkHsVarPV v@(getLoc -> l) = return $ L (na2la l) (PatBuilderVar v)
  mkHsLitPV lit@(L l a) = do
    checkUnboxedStringLitPat lit
    return $ L l (PatBuilderPat (LitPat noExtField a))
  mkHsOverLitPV (L l a) = return $ L l (PatBuilderOverLit a)
  mkHsWildCardPV l = return $ L l (PatBuilderPat (WildPat noExtField))
  mkHsTySigPV l b sig anns = do
    p <- checkLPat b
    cs <- addAnnsAt (locA l) []
    return $ L l (PatBuilderPat (SigPat (ApiAnn (realSrcSpan $ locA l) anns cs) p (mkHsPatSigType sig)))
  mkHsExplicitListPV l xs anns = do
    ps <- traverse checkLPat xs
    cs <- addAnnsAt l []
    return (L (noAnnSrcSpan l) (PatBuilderPat (ListPat (ApiAnn (realSrcSpan l) anns cs) ps)))
  mkHsSplicePV (L l sp) = return $ L l (PatBuilderPat (SplicePat noExtField sp))
  mkHsRecordPV l _ a (fbinds, ddLoc) anns = do
    cs <- addAnnsAt l []
    r <- mkPatRec a (mk_rec_fields fbinds ddLoc) (ApiAnn (realSrcSpan l) anns cs)
    checkRecordSyntax (L (noAnnSrcSpan l) r)
  mkHsNegAppPV l (L lp p) _anns = do
    lit <- case p of
      PatBuilderOverLit pos_lit -> return (L (locA lp) pos_lit)
      _ -> patFail l (text "-" <> ppr p)
    return $ L (noAnnSrcSpan l) (PatBuilderPat (mkNPat lit (Just noSyntaxExpr)))
  mkHsSectionR_PV l op p = patFail l (pprInfixOcc (unLoc op) <> ppr p)
  mkHsViewPatPV l a b anns = do
    p <- checkLPat b
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (PatBuilderPat (ViewPat (ApiAnn (realSrcSpan l) anns cs) a p))
  mkHsAsPatPV l v e a = do
    p <- checkLPat e
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (PatBuilderPat (AsPat (ApiAnn (realSrcSpan l) a cs) v p))
  mkHsLazyPatPV l e a = do
    p <- checkLPat (reLocA e)
    cs <- addAnnsAt l []
    return $ L (noAnnSrcSpan l) (PatBuilderPat (LazyPat (ApiAnn (realSrcSpan l) a cs) p))
  mkHsBangPatPV l e a = do
    p <- checkLPat (reLocA e)
    cs <- addAnnsAt l []
    let pb = BangPat (ApiAnn (realSrcSpan l) a cs) p
    hintBangPat l pb
    return $ L (noAnnSrcSpan l) (PatBuilderPat pb)
  mkSumOrTuplePV = mkSumOrTuplePat
  rejectPragmaPV _ = return ()



checkUnboxedStringLitPat :: Located (HsLit GhcPs) -> PV ()
checkUnboxedStringLitPat (L loc lit) =
  case lit of
    HsStringPrim _ _  -- Trac #13260
      -> addFatalError loc (text "Illegal unboxed string literal in pattern:" $$ ppr lit)
    _ -> return ()

mkPatRec ::
  LocatedA (PatBuilder GhcPs) ->
  HsRecFields GhcPs (LocatedA (PatBuilder GhcPs)) ->
  ApiAnn ->
  PV (PatBuilder GhcPs)
mkPatRec (unLoc -> PatBuilderVar c) (HsRecFields fs dd) anns
  | isRdrDataCon (unLoc c)
  = do fs <- mapM checkPatField fs
       return $ PatBuilderPat $ ConPat
         { pat_con_ext = anns
         , pat_con = c
         , pat_args = RecCon (HsRecFields fs dd)
         }
mkPatRec p _ _ =
  addFatalError (getLocA p) $ text "Not a record constructor:" <+> ppr p

{- Note [Ambiguous syntactic categories]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

There are places in the grammar where we do not know whether we are parsing an
expression or a pattern without unlimited lookahead (which we do not have in
'happy'):

View patterns:

    f (Con a b     ) = ...  -- 'Con a b' is a pattern
    f (Con a b -> x) = ...  -- 'Con a b' is an expression

do-notation:

    do { Con a b <- x } -- 'Con a b' is a pattern
    do { Con a b }      -- 'Con a b' is an expression

Guards:

    x | True <- p && q = ...  -- 'True' is a pattern
    x | True           = ...  -- 'True' is an expression

Top-level value/function declarations (FunBind/PatBind):

    f ! a         -- TH splice
    f ! a = ...   -- function declaration

    Until we encounter the = sign, we don't know if it's a top-level
    TemplateHaskell splice where ! is used, or if it's a function declaration
    where ! is bound.

There are also places in the grammar where we do not know whether we are
parsing an expression or a command:

    proc x -> do { (stuff) -< x }   -- 'stuff' is an expression
    proc x -> do { (stuff) }        -- 'stuff' is a command

    Until we encounter arrow syntax (-<) we don't know whether to parse 'stuff'
    as an expression or a command.

In fact, do-notation is subject to both ambiguities:

    proc x -> do { (stuff) -< x }        -- 'stuff' is an expression
    proc x -> do { (stuff) <- f -< x }   -- 'stuff' is a pattern
    proc x -> do { (stuff) }             -- 'stuff' is a command

There are many possible solutions to this problem. For an overview of the ones
we decided against, see Note [Resolving parsing ambiguities: non-taken alternatives]

The solution that keeps basic definitions (such as HsExpr) clean, keeps the
concerns local to the parser, and does not require duplication of hsSyn types,
or an extra pass over the entire AST, is to parse into an overloaded
parser-validator (a so-called tagless final encoding):

    class DisambECP b where ...
    instance DisambECP (HsCmd GhcPs) where ...
    instance DisambECP (HsExp GhcPs) where ...
    instance DisambECP (PatBuilder GhcPs) where ...

The 'DisambECP' class contains functions to build and validate 'b'. For example,
to add parentheses we have:

  mkHsParPV :: DisambECP b => SrcSpan -> Located b -> PV (Located b)

'mkHsParPV' will wrap the inner value in HsCmdPar for commands, HsPar for
expressions, and 'PatBuilderPar' for patterns (later transformed into ParPat,
see Note [PatBuilder]).

Consider the 'alts' production used to parse case-of alternatives:

  alts :: { Located ([AddApiAnn],[LMatch GhcPs (LHsExpr GhcPs)]) }
    : alts1     { sL1 $1 (fst $ unLoc $1,snd $ unLoc $1) }
    | ';' alts  { sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2) }

We abstract over LHsExpr GhcPs, and it becomes:

  alts :: { forall b. DisambECP b => PV (Located ([AddApiAnn],[LMatch GhcPs (Located b)])) }
    : alts1     { $1 >>= \ $1 ->
                  return $ sL1 $1 (fst $ unLoc $1,snd $ unLoc $1) }
    | ';' alts  { $2 >>= \ $2 ->
                  return $ sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2) }

Compared to the initial definition, the added bits are:

    forall b. DisambECP b => PV ( ... ) -- in the type signature
    $1 >>= \ $1 -> return $             -- in one reduction rule
    $2 >>= \ $2 -> return $             -- in another reduction rule

The overhead is constant relative to the size of the rest of the reduction
rule, so this approach scales well to large parser productions.

Note that we write ($1 >>= \ $1 -> ...), so the second $1 is in a binding
position and shadows the previous $1. We can do this because internally
'happy' desugars $n to happy_var_n, and the rationale behind this idiom
is to be able to write (sLL $1 $>) later on. The alternative would be to
write this as ($1 >>= \ fresh_name -> ...), but then we couldn't refer
to the last fresh name as $>.
-}


{- Note [Resolving parsing ambiguities: non-taken alternatives]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Alternative I, extra constructors in GHC.Hs.Expr
------------------------------------------------
We could add extra constructors to HsExpr to represent command-specific and
pattern-specific syntactic constructs. Under this scheme, we parse patterns
and commands as expressions and rejig later.  This is what GHC used to do, and
it polluted 'HsExpr' with irrelevant constructors:

  * for commands: 'HsArrForm', 'HsArrApp'
  * for patterns: 'EWildPat', 'EAsPat', 'EViewPat', 'ELazyPat'

(As of now, we still do that for patterns, but we plan to fix it).

There are several issues with this:

  * The implementation details of parsing are leaking into hsSyn definitions.

  * Code that uses HsExpr has to panic on these impossible-after-parsing cases.

  * HsExpr is arbitrarily selected as the extension basis. Why not extend
    HsCmd or HsPat with extra constructors instead?

Alternative II, extra constructors in GHC.Hs.Expr for GhcPs
-----------------------------------------------------------
We could address some of the problems with Alternative I by using Trees That
Grow and extending HsExpr only in the GhcPs pass. However, GhcPs corresponds to
the output of parsing, not to its intermediate results, so we wouldn't want
them there either.

Alternative III, extra constructors in GHC.Hs.Expr for GhcPrePs
---------------------------------------------------------------
We could introduce a new pass, GhcPrePs, to keep GhcPs pristine.
Unfortunately, creating a new pass would significantly bloat conversion code
and slow down the compiler by adding another linear-time pass over the entire
AST. For example, in order to build HsExpr GhcPrePs, we would need to build
HsLocalBinds GhcPrePs (as part of HsLet), and we never want HsLocalBinds
GhcPrePs.


Alternative IV, sum type and bottom-up data flow
------------------------------------------------
Expressions and commands are disjoint. There are no user inputs that could be
interpreted as either an expression or a command depending on outer context:

  5        -- definitely an expression
  x -< y   -- definitely a command

Even though we have both 'HsLam' and 'HsCmdLam', we can look at
the body to disambiguate:

  \p -> 5        -- definitely an expression
  \p -> x -< y   -- definitely a command

This means we could use a bottom-up flow of information to determine
whether we are parsing an expression or a command, using a sum type
for intermediate results:

  Either (LHsExpr GhcPs) (LHsCmd GhcPs)

There are two problems with this:

  * We cannot handle the ambiguity between expressions and
    patterns, which are not disjoint.

  * Bottom-up flow of information leads to poor error messages. Consider

        if ... then 5 else (x -< y)

    Do we report that '5' is not a valid command or that (x -< y) is not a
    valid expression?  It depends on whether we want the entire node to be
    'HsIf' or 'HsCmdIf', and this information flows top-down, from the
    surrounding parsing context (are we in 'proc'?)

Alternative V, backtracking with parser combinators
---------------------------------------------------
One might think we could sidestep the issue entirely by using a backtracking
parser and doing something along the lines of (try pExpr <|> pPat).

Turns out, this wouldn't work very well, as there can be patterns inside
expressions (e.g. via 'case', 'let', 'do') and expressions inside patterns
(e.g. view patterns). To handle this, we would need to backtrack while
backtracking, and unbound levels of backtracking lead to very fragile
performance.

Alternative VI, an intermediate data type
-----------------------------------------
There are common syntactic elements of expressions, commands, and patterns
(e.g. all of them must have balanced parentheses), and we can capture this
common structure in an intermediate data type, Frame:

data Frame
  = FrameVar RdrName
    -- ^ Identifier: Just, map, BS.length
  | FrameTuple [LTupArgFrame] Boxity
    -- ^ Tuple (section): (a,b) (a,b,c) (a,,) (,a,)
  | FrameTySig LFrame (LHsSigWcType GhcPs)
    -- ^ Type signature: x :: ty
  | FramePar (SrcSpan, SrcSpan) LFrame
    -- ^ Parentheses
  | FrameIf LFrame LFrame LFrame
    -- ^ If-expression: if p then x else y
  | FrameCase LFrame [LFrameMatch]
    -- ^ Case-expression: case x of { p1 -> e1; p2 -> e2 }
  | FrameDo (HsStmtContext Name) [LFrameStmt]
    -- ^ Do-expression: do { s1; a <- s2; s3 }
  ...
  | FrameExpr (HsExpr GhcPs)   -- unambiguously an expression
  | FramePat (HsPat GhcPs)     -- unambiguously a pattern
  | FrameCommand (HsCmd GhcPs) -- unambiguously a command

To determine which constructors 'Frame' needs to have, we take the union of
intersections between HsExpr, HsCmd, and HsPat.

The intersection between HsPat and HsExpr:

  HsPat  =  VarPat   | TuplePat      | SigPat        | ParPat   | ...
  HsExpr =  HsVar    | ExplicitTuple | ExprWithTySig | HsPar    | ...
  -------------------------------------------------------------------
  Frame  =  FrameVar | FrameTuple    | FrameTySig    | FramePar | ...

The intersection between HsCmd and HsExpr:

  HsCmd  = HsCmdIf | HsCmdCase | HsCmdDo | HsCmdPar
  HsExpr = HsIf    | HsCase    | HsDo    | HsPar
  ------------------------------------------------
  Frame = FrameIf  | FrameCase | FrameDo | FramePar

The intersection between HsCmd and HsPat:

  HsPat  = ParPat   | ...
  HsCmd  = HsCmdPar | ...
  -----------------------
  Frame  = FramePar | ...

Take the union of each intersection and this yields the final 'Frame' data
type. The problem with this approach is that we end up duplicating a good
portion of hsSyn:

    Frame         for  HsExpr, HsPat, HsCmd
    TupArgFrame   for  HsTupArg
    FrameMatch    for  Match
    FrameStmt     for  StmtLR
    FrameGRHS     for  GRHS
    FrameGRHSs    for  GRHSs
    ...

Alternative VII, a product type
-------------------------------
We could avoid the intermediate representation of Alternative VI by parsing
into a product of interpretations directly:

    -- See Note [Parser-Validator]
    type ExpCmdPat = ( PV (LHsExpr GhcPs)
                     , PV (LHsCmd GhcPs)
                     , PV (LHsPat GhcPs) )

This means that in positions where we do not know whether to produce
expression, a pattern, or a command, we instead produce a parser-validator for
each possible option.

Then, as soon as we have parsed far enough to resolve the ambiguity, we pick
the appropriate component of the product, discarding the rest:

    checkExpOf3 (e, _, _) = e  -- interpret as an expression
    checkCmdOf3 (_, c, _) = c  -- interpret as a command
    checkPatOf3 (_, _, p) = p  -- interpret as a pattern

We can easily define ambiguities between arbitrary subsets of interpretations.
For example, when we know ahead of type that only an expression or a command is
possible, but not a pattern, we can use a smaller type:

    -- See Note [Parser-Validator]
    type ExpCmd = (PV (LHsExpr GhcPs), PV (LHsCmd GhcPs))

    checkExpOf2 (e, _) = e  -- interpret as an expression
    checkCmdOf2 (_, c) = c  -- interpret as a command

However, there is a slight problem with this approach, namely code duplication
in parser productions. Consider the 'alts' production used to parse case-of
alternatives:

  alts :: { Located ([AddApiAnn],[LMatch GhcPs (LHsExpr GhcPs)]) }
    : alts1     { sL1 $1 (fst $ unLoc $1,snd $ unLoc $1) }
    | ';' alts  { sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2) }

Under the new scheme, we have to completely duplicate its type signature and
each reduction rule:

  alts :: { ( PV (Located ([AddApiAnn],[LMatch GhcPs (LHsExpr GhcPs)])) -- as an expression
            , PV (Located ([AddApiAnn],[LMatch GhcPs (LHsCmd GhcPs)]))  -- as a command
            ) }
    : alts1
        { ( checkExpOf2 $1 >>= \ $1 ->
            return $ sL1 $1 (fst $ unLoc $1,snd $ unLoc $1)
          , checkCmdOf2 $1 >>= \ $1 ->
            return $ sL1 $1 (fst $ unLoc $1,snd $ unLoc $1)
          ) }
    | ';' alts
        { ( checkExpOf2 $2 >>= \ $2 ->
            return $ sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2)
          , checkCmdOf2 $2 >>= \ $2 ->
            return $ sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2)
          ) }

And the same goes for other productions: 'altslist', 'alts1', 'alt', 'alt_rhs',
'ralt', 'gdpats', 'gdpat', 'exp', ... and so on. That is a lot of code!

Alternative VIII, a function from a GADT
----------------------------------------
We could avoid code duplication of the Alternative VII by representing the product
as a function from a GADT:

    data ExpCmdG b where
      ExpG :: ExpCmdG HsExpr
      CmdG :: ExpCmdG HsCmd

    type ExpCmd = forall b. ExpCmdG b -> PV (Located (b GhcPs))

    checkExp :: ExpCmd -> PV (LHsExpr GhcPs)
    checkCmd :: ExpCmd -> PV (LHsCmd GhcPs)
    checkExp f = f ExpG  -- interpret as an expression
    checkCmd f = f CmdG  -- interpret as a command

Consider the 'alts' production used to parse case-of alternatives:

  alts :: { Located ([AddApiAnn],[LMatch GhcPs (LHsExpr GhcPs)]) }
    : alts1     { sL1 $1 (fst $ unLoc $1,snd $ unLoc $1) }
    | ';' alts  { sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2) }

We abstract over LHsExpr, and it becomes:

  alts :: { forall b. ExpCmdG b -> PV (Located ([AddApiAnn],[LMatch GhcPs (Located (b GhcPs))])) }
    : alts1
        { \tag -> $1 tag >>= \ $1 ->
                  return $ sL1 $1 (fst $ unLoc $1,snd $ unLoc $1) }
    | ';' alts
        { \tag -> $2 tag >>= \ $2 ->
                  return $ sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2) }

Note that 'ExpCmdG' is a singleton type, the value is completely
determined by the type:

  when (b~HsExpr),  tag = ExpG
  when (b~HsCmd),   tag = CmdG

This is a clear indication that we can use a class to pass this value behind
the scenes:

  class    ExpCmdI b      where expCmdG :: ExpCmdG b
  instance ExpCmdI HsExpr where expCmdG = ExpG
  instance ExpCmdI HsCmd  where expCmdG = CmdG

And now the 'alts' production is simplified, as we no longer need to
thread 'tag' explicitly:

  alts :: { forall b. ExpCmdI b => PV (Located ([AddApiAnn],[LMatch GhcPs (Located (b GhcPs))])) }
    : alts1     { $1 >>= \ $1 ->
                  return $ sL1 $1 (fst $ unLoc $1,snd $ unLoc $1) }
    | ';' alts  { $2 >>= \ $2 ->
                  return $ sLL $1 $> ((mj AnnSemi $1:(fst $ unLoc $2)),snd $ unLoc $2) }

This encoding works well enough, but introduces an extra GADT unlike the
tagless final encoding, and there's no need for this complexity.

-}

{- Note [PatBuilder]
~~~~~~~~~~~~~~~~~~~~
Unlike HsExpr or HsCmd, the Pat type cannot accommodate all intermediate forms,
so we introduce the notion of a PatBuilder.

Consider a pattern like this:

  Con a b c

We parse arguments to "Con" one at a time in the  fexp aexp  parser production,
building the result with mkHsAppPV, so the intermediate forms are:

  1. Con
  2. Con a
  3. Con a b
  4. Con a b c

In 'HsExpr', we have 'HsApp', so the intermediate forms are represented like
this (pseudocode):

  1. "Con"
  2. HsApp "Con" "a"
  3. HsApp (HsApp "Con" "a") "b"
  3. HsApp (HsApp (HsApp "Con" "a") "b") "c"

Similarly, in 'HsCmd' we have 'HsCmdApp'. In 'Pat', however, what we have
instead is 'ConPatIn', which is very awkward to modify and thus unsuitable for
the intermediate forms.

We also need an intermediate representation to postpone disambiguation between
FunBind and PatBind. Consider:

  a `Con` b = ...
  a `fun` b = ...

How do we know that (a `Con` b) is a PatBind but (a `fun` b) is a FunBind? We
learn this by inspecting an intermediate representation in 'isFunLhs' and
seeing that 'Con' is a data constructor but 'f' is not. We need an intermediate
representation capable of representing both a FunBind and a PatBind, so Pat is
insufficient.

PatBuilder is an extension of Pat that is capable of representing intermediate
parsing results for patterns and function bindings:

  data PatBuilder p
    = PatBuilderPat (Pat p)
    | PatBuilderApp (LocatedA (PatBuilder p)) (LocatedA (PatBuilder p))
    | PatBuilderOpApp (LocatedA (PatBuilder p)) (LocatedA RdrName) (LocatedA (PatBuilder p))
    ...

It can represent any pattern via 'PatBuilderPat', but it also has a variety of
other constructors which were added by following a simple principle: we never
pattern match on the pattern stored inside 'PatBuilderPat'.
-}

---------------------------------------------------------------------------
-- Miscellaneous utilities

-- | Check if a fixity is valid. We support bypassing the usual bound checks
-- for some special operators.
checkPrecP
        :: Located (SourceText,Int)              -- ^ precedence
        -> Located (OrdList (LocatedN RdrName))  -- ^ operators
        -> P ()
checkPrecP (L l (_,i)) (L _ ol)
 | 0 <= i, i <= maxPrecedence = pure ()
 | all specialOp ol = pure ()
 | otherwise = addFatalError l (text ("Precedence out of range: " ++ show i))
  where
    -- If you change this, consider updating Note [Fixity of (->)] in GHC/Types.hs
    specialOp op = unLoc op `elem` [ eqTyCon_RDR
                                   , getRdrName unrestrictedFunTyCon ]

mkRecConstrOrUpdate
        :: LHsExpr GhcPs
        -> SrcSpan
        -> ([LHsRecField GhcPs (LHsExpr GhcPs)], Maybe SrcSpan)
        -> ApiAnn
        -> PV (HsExpr GhcPs)

mkRecConstrOrUpdate (L _ (HsVar _ (L l c))) _ (fs,dd) anns
  | isRdrDataCon c
  = return (mkRdrRecordCon (L l c) (mk_rec_fields fs dd) anns)
mkRecConstrOrUpdate exp _ (fs,dd) anns
  | Just dd_loc <- dd = addFatalError dd_loc (text "You cannot use `..' in a record update")
  | otherwise
             = return (mkRdrRecordUpd exp (map (fmap mk_rec_upd_field) fs) anns)

mkRdrRecordUpd
  :: LHsExpr GhcPs -> [LHsRecUpdField GhcPs] -> ApiAnn -> HsExpr GhcPs
mkRdrRecordUpd exp flds anns
  = RecordUpd { rupd_ext  = anns
              , rupd_expr = exp
              , rupd_flds = flds }

mkRdrRecordCon
  :: LocatedN RdrName -> HsRecordBinds GhcPs -> ApiAnn -> HsExpr GhcPs
mkRdrRecordCon con flds anns
  = RecordCon { rcon_ext = anns, rcon_con_name = con, rcon_flds = flds }

mk_rec_fields :: [LHsRecField id arg] -> Maybe SrcSpan -> HsRecFields id arg
mk_rec_fields fs Nothing = HsRecFields { rec_flds = fs, rec_dotdot = Nothing }
mk_rec_fields fs (Just s)  = HsRecFields { rec_flds = fs
                                     , rec_dotdot = Just (L s (length fs)) }

mk_rec_upd_field :: HsRecField GhcPs (LHsExpr GhcPs) -> HsRecUpdField GhcPs
mk_rec_upd_field (HsRecField noAnn (L loc (FieldOcc _ rdr)) arg pun)
  = HsRecField noAnn (L loc (Unambiguous noExtField rdr)) arg pun

mkInlinePragma :: SourceText -> (InlineSpec, RuleMatchInfo) -> Maybe Activation
               -> InlinePragma
-- The (Maybe Activation) is because the user can omit
-- the activation spec (and usually does)
mkInlinePragma src (inl, match_info) mb_act
  = InlinePragma { inl_src = src -- Note [Pragma source text] in GHC.Types.Basic
                 , inl_inline = inl
                 , inl_sat    = Nothing
                 , inl_act    = act
                 , inl_rule   = match_info }
  where
    act = case mb_act of
            Just act -> act
            Nothing  -> -- No phase specified
                        case inl of
                          NoInline -> NeverActive
                          _other   -> AlwaysActive

-----------------------------------------------------------------------------
-- utilities for foreign declarations

-- construct a foreign import declaration
--
mkImport :: Located CCallConv
         -> Located Safety
         -> (Located StringLiteral, LocatedN RdrName, LHsSigType GhcPs)
         -> P (ApiAnn -> HsDecl GhcPs)
mkImport cconv safety (L loc (StringLiteral esrc entity), v, ty) =
    case unLoc cconv of
      CCallConv          -> mkCImport
      CApiConv           -> mkCImport
      StdCallConv        -> mkCImport
      PrimCallConv       -> mkOtherImport
      JavaScriptCallConv -> mkOtherImport
  where
    -- Parse a C-like entity string of the following form:
    --   "[static] [chname] [&] [cid]" | "dynamic" | "wrapper"
    -- If 'cid' is missing, the function name 'v' is used instead as symbol
    -- name (cf section 8.5.1 in Haskell 2010 report).
    mkCImport = do
      let e = unpackFS entity
      case parseCImport cconv safety (mkExtName (unLoc v)) e (L loc esrc) of
        Nothing         -> addFatalError loc (text "Malformed entity string")
        Just importSpec -> returnSpec importSpec

    -- currently, all the other import conventions only support a symbol name in
    -- the entity string. If it is missing, we use the function name instead.
    mkOtherImport = returnSpec importSpec
      where
        entity'    = if nullFS entity
                        then mkExtName (unLoc v)
                        else entity
        funcTarget = CFunction (StaticTarget esrc entity' Nothing True)
        importSpec = CImport cconv safety Nothing funcTarget (L loc esrc)

    returnSpec spec = return $ \ann -> ForD noExtField $ ForeignImport
          { fd_i_ext  = ann
          , fd_name   = v
          , fd_sig_ty = ty
          , fd_fi     = spec
          }



-- the string "foo" is ambiguous: either a header or a C identifier.  The
-- C identifier case comes first in the alternatives below, so we pick
-- that one.
parseCImport :: Located CCallConv -> Located Safety -> FastString -> String
             -> Located SourceText
             -> Maybe ForeignImport
parseCImport cconv safety nm str sourceText =
 listToMaybe $ map fst $ filter (null.snd) $
     readP_to_S parse str
 where
   parse = do
       skipSpaces
       r <- choice [
          string "dynamic" >> return (mk Nothing (CFunction DynamicTarget)),
          string "wrapper" >> return (mk Nothing CWrapper),
          do optional (token "static" >> skipSpaces)
             ((mk Nothing <$> cimp nm) +++
              (do h <- munch1 hdr_char
                  skipSpaces
                  mk (Just (Header (SourceText h) (mkFastString h)))
                      <$> cimp nm))
         ]
       skipSpaces
       return r

   token str = do _ <- string str
                  toks <- look
                  case toks of
                      c : _
                       | id_char c -> pfail
                      _            -> return ()

   mk h n = CImport cconv safety h n sourceText

   hdr_char c = not (isSpace c)
   -- header files are filenames, which can contain
   -- pretty much any char (depending on the platform),
   -- so just accept any non-space character
   id_first_char c = isAlpha    c || c == '_'
   id_char       c = isAlphaNum c || c == '_'

   cimp nm = (ReadP.char '&' >> skipSpaces >> CLabel <$> cid)
             +++ (do isFun <- case unLoc cconv of
                               CApiConv ->
                                  option True
                                         (do token "value"
                                             skipSpaces
                                             return False)
                               _ -> return True
                     cid' <- cid
                     return (CFunction (StaticTarget NoSourceText cid'
                                        Nothing isFun)))
          where
            cid = return nm +++
                  (do c  <- satisfy id_first_char
                      cs <-  many (satisfy id_char)
                      return (mkFastString (c:cs)))


-- construct a foreign export declaration
--
mkExport :: Located CCallConv
         -> (Located StringLiteral, LocatedN RdrName, LHsSigType GhcPs)
         -> P (ApiAnn -> HsDecl GhcPs)
mkExport (L lc cconv) (L le (StringLiteral esrc entity), v, ty)
 = return $ \ann -> ForD noExtField $
   ForeignExport { fd_e_ext = ann, fd_name = v, fd_sig_ty = ty
                 , fd_fe = CExport (L lc (CExportStatic esrc entity' cconv))
                                   (L le esrc) }
  where
    entity' | nullFS entity = mkExtName (unLoc v)
            | otherwise     = entity

-- Supplying the ext_name in a foreign decl is optional; if it
-- isn't there, the Haskell name is assumed. Note that no transformation
-- of the Haskell name is then performed, so if you foreign export (++),
-- it's external name will be "++". Too bad; it's important because we don't
-- want z-encoding (e.g. names with z's in them shouldn't be doubled)
--
mkExtName :: RdrName -> CLabelString
mkExtName rdrNm = mkFastString (occNameString (rdrNameOcc rdrNm))

--------------------------------------------------------------------------------
-- Help with module system imports/exports

data ImpExpSubSpec = ImpExpAbs
                   | ImpExpAll
                   | ImpExpList [Located ImpExpQcSpec]
                   | ImpExpAllWith [Located ImpExpQcSpec]

data ImpExpQcSpec = ImpExpQcName (LocatedN RdrName)
                  | ImpExpQcType RealSrcSpan (LocatedN RdrName)
                  | ImpExpQcWildcard

mkModuleImpExp :: [AddApiAnn] -> Located ImpExpQcSpec -> ImpExpSubSpec -> P (IE GhcPs)
mkModuleImpExp anns (L l specname) subs = do
  cs <- addAnnsAt l []
  let ann = ApiAnn (realSrcSpan l) anns cs
  case subs of
    ImpExpAbs
      | isVarNameSpace (rdrNameSpace name)
                       -> return $ IEVar ann (L l (ieNameFromSpec specname))
      | otherwise      -> IEThingAbs ann . L l <$> nameT
    ImpExpAll          -> IEThingAll ann . L l <$> nameT
    ImpExpList xs      ->
      (\newName -> IEThingWith ann (L l newName)
        NoIEWildcard (wrapped xs) []) <$> nameT
    ImpExpAllWith xs                       ->
      do allowed <- getBit PatternSynonymsBit
         if allowed
          then
            let withs = map unLoc xs
                pos   = maybe NoIEWildcard IEWildcard
                          (findIndex isImpExpQcWildcard withs)
                ies   = wrapped $ filter (not . isImpExpQcWildcard . unLoc) xs
            in (\newName
                        -> IEThingWith ann (L l newName) pos ies [])
               <$> nameT
          else addFatalError l
            (text "Illegal export form (use PatternSynonyms to enable)")
  where
    name = ieNameVal specname
    nameT =
      if isVarNameSpace (rdrNameSpace name)
        then addFatalError l
              (text "Expecting a type constructor but found a variable,"
               <+> quotes (ppr name) <> text "."
              $$ if isSymOcc $ rdrNameOcc name
                   then text "If" <+> quotes (ppr name)
                        <+> text "is a type constructor"
           <+> text "then enable ExplicitNamespaces and use the 'type' keyword."
                   else empty)
        else return $ ieNameFromSpec specname

    ieNameVal (ImpExpQcName ln)   = unLoc ln
    ieNameVal (ImpExpQcType _ ln) = unLoc ln
    ieNameVal (ImpExpQcWildcard)  = panic "ieNameVal got wildcard"

    ieNameFromSpec (ImpExpQcName   ln) = IEName ln
    ieNameFromSpec (ImpExpQcType _ ln) = IEType ln
    ieNameFromSpec (ImpExpQcWildcard) = panic "ieName got wildcard"

    wrapped = map (mapLoc ieNameFromSpec)

mkTypeImpExp :: LocatedN RdrName   -- TcCls or Var name space
             -> P (LocatedN RdrName)
mkTypeImpExp name =
  do allowed <- getBit ExplicitNamespacesBit
     unless allowed $ addError (getLocA name) $
       text "Illegal keyword 'type' (use ExplicitNamespaces to enable)"
     return (fmap (`setRdrNameSpace` tcClsName) name)

checkImportSpec :: LocatedL [LIE GhcPs] -> P (LocatedL [LIE GhcPs])
checkImportSpec ie@(L _ specs) =
    case [l | (L l (IEThingWith _ _ (IEWildcard _) _ _)) <- specs] of
      [] -> return ie
      (l:_) -> importSpecError (locA l)
  where
    importSpecError l =
      addFatalError l
        (text "Illegal import form, this syntax can only be used to bundle"
        $+$ text "pattern synonyms with types in module exports.")

-- In the correct order
mkImpExpSubSpec :: [Located ImpExpQcSpec] -> P ([AddApiAnn], ImpExpSubSpec)
mkImpExpSubSpec [] = return ([], ImpExpList [])
mkImpExpSubSpec [L _ ImpExpQcWildcard] =
  return ([], ImpExpAll)
mkImpExpSubSpec xs =
  if (any (isImpExpQcWildcard . unLoc) xs)
    then return $ ([], ImpExpAllWith xs)
    else return $ ([], ImpExpList xs)

isImpExpQcWildcard :: ImpExpQcSpec -> Bool
isImpExpQcWildcard ImpExpQcWildcard = True
isImpExpQcWildcard _                = False

-----------------------------------------------------------------------------
-- Warnings and failures

warnPrepositiveQualifiedModule :: SrcSpan -> P ()
warnPrepositiveQualifiedModule span =
  addWarning Opt_WarnPrepositiveQualifiedModule span msg
  where
    msg = text "Found" <+> quotes (text "qualified")
           <+> text "in prepositive position"
       $$ text "Suggested fix: place " <+> quotes (text "qualified")
           <+> text "after the module name instead."

failOpNotEnabledImportQualifiedPost :: SrcSpan -> P ()
failOpNotEnabledImportQualifiedPost loc = addError loc msg
  where
    msg = text "Found" <+> quotes (text "qualified")
          <+> text "in postpositive position. "
      $$ text "To allow this, enable language extension 'ImportQualifiedPost'"

failOpImportQualifiedTwice :: SrcSpan -> P ()
failOpImportQualifiedTwice loc = addError loc msg
  where
    msg = text "Multiple occurrences of 'qualified'"

warnStarIsType :: SrcSpan -> P ()
warnStarIsType span = addWarning Opt_WarnStarIsType span msg
  where
    msg =  text "Using" <+> quotes (text "*")
           <+> text "(or its Unicode variant) to mean"
           <+> quotes (text "Data.Kind.Type")
        $$ text "relies on the StarIsType extension, which will become"
        $$ text "deprecated in the future."
        $$ text "Suggested fix: use" <+> quotes (text "Type")
           <+> text "from" <+> quotes (text "Data.Kind") <+> text "instead."

warnStarBndr :: SrcSpan -> P ()
warnStarBndr span = addWarning Opt_WarnStarBinder span msg
  where
    msg =  text "Found binding occurrence of" <+> quotes (text "*")
           <+> text "yet StarIsType is enabled."
        $$ text "NB. To use (or export) this operator in"
           <+> text "modules with StarIsType,"
        $$ text "    including the definition module, you must qualify it."

failOpFewArgs :: LocatedN RdrName -> P a
failOpFewArgs (L loc op) =
  do { star_is_type <- getBit StarIsTypeBit
     ; let msg = too_few $$ starInfo star_is_type op
     ; addFatalError (locA loc) msg }
  where
    too_few = text "Operator applied to too few arguments:" <+> ppr op

failOpDocPrev :: SrcSpan -> P a
failOpDocPrev loc = addFatalError loc msg
  where
    msg = text "Unexpected documentation comment."

-----------------------------------------------------------------------------
-- Misc utils

data PV_Context =
  PV_Context
    { pv_options :: ParserFlags
    , pv_hint :: SDoc  -- See Note [Parser-Validator Hint]
    }

data PV_Accum =
  PV_Accum
    { pv_messages :: DynFlags -> Messages
    , pv_comment_q :: [RealLocated AnnotationComment]
    , pv_annotations_comments :: [(RealSrcSpan,[RealLocated AnnotationComment])]
    }

data PV_Result a = PV_Ok PV_Accum a | PV_Failed PV_Accum

-- See Note [Parser-Validator]
newtype PV a = PV { unPV :: PV_Context -> PV_Accum -> PV_Result a }

instance Functor PV where
  fmap = liftM

instance Applicative PV where
  pure a = a `seq` PV (\_ acc -> PV_Ok acc a)
  (<*>) = ap

instance Monad PV where
  m >>= f = PV $ \ctx acc ->
    case unPV m ctx acc of
      PV_Ok acc' a -> unPV (f a) ctx acc'
      PV_Failed acc' -> PV_Failed acc'

runPV :: PV a -> P a
runPV = runPV_msg empty

runPV_msg :: SDoc -> PV a -> P a
runPV_msg msg m =
  P $ \s ->
    let
      pv_ctx = PV_Context
        { pv_options = options s
        , pv_hint = msg }
      pv_acc = PV_Accum
        { pv_messages = messages s
        -- , pv_annotations = annotations s
        , pv_comment_q = comment_q s
        , pv_annotations_comments = annotations_comments s }
      mkPState acc' =
        s { messages = pv_messages acc'
          -- AZ , annotations = pv_annotations acc'
          , comment_q = pv_comment_q acc'
          , annotations_comments = pv_annotations_comments acc' }
    in
      case unPV m pv_ctx pv_acc of
        PV_Ok acc' a -> POk (mkPState acc') a
        PV_Failed acc' -> PFailed (mkPState acc')

localPV_msg :: (SDoc -> SDoc) -> PV a -> PV a
localPV_msg f m =
  let modifyHint ctx = ctx{pv_hint = f (pv_hint ctx)} in
  PV (\ctx acc -> unPV m (modifyHint ctx) acc)

instance MonadP PV where
  addError srcspan msg =
    PV $ \ctx acc@PV_Accum{pv_messages=m} ->
      let msg' = msg $$ pv_hint ctx in
      PV_Ok acc{pv_messages=appendError srcspan msg' m} ()
  addWarning option srcspan warning =
    PV $ \PV_Context{pv_options=o} acc@PV_Accum{pv_messages=m} ->
      PV_Ok acc{pv_messages=appendWarning o option srcspan warning m} ()
  addFatalError srcspan msg =
    addError srcspan msg >> PV (const PV_Failed)
  getBit ext =
    PV $ \ctx acc ->
      let b = ext `xtest` pExtsBitmap (pv_options ctx) in
      PV_Ok acc $! b
  addAnnotation l a v =
    PV $ \_ acc ->
      let
        (comment_q', new_ann_comments) = allocateComments l (pv_comment_q acc)
        annotations_comments' = new_ann_comments ++ pv_annotations_comments acc
        -- annotations' = ((l,a), [v]) : pv_annotations acc
        acc' = acc
          {
          -- AZ  pv_annotations = annotations'
          -- ,
            pv_comment_q = comment_q'
          , pv_annotations_comments = annotations_comments' }
      in
        PV_Ok acc' ()
  allocateCommentsP ss = PV $ \_ s ->
    let (comment_q', newAnns) = allocateComments ss (pv_comment_q s) in
      PV_Ok s {
         pv_comment_q = comment_q'
       , pv_annotations_comments = newAnns ++ (pv_annotations_comments s)
       } (newComments newAnns)

{- Note [Parser-Validator]
~~~~~~~~~~~~~~~~~~~~~~~~~~

When resolving ambiguities, we need to postpone failure to make a choice later.
For example, if we have ambiguity between some A and B, our parser could be

  abParser :: P (Maybe A, Maybe B)

This way we can represent four possible outcomes of parsing:

    (Just a, Nothing)       -- definitely A
    (Nothing, Just b)       -- definitely B
    (Just a, Just b)        -- either A or B
    (Nothing, Nothing)      -- neither A nor B

However, if we want to report informative parse errors, accumulate warnings,
and add API annotations, we are better off using 'P' instead of 'Maybe':

  abParser :: P (P A, P B)

So we have an outer layer of P that consumes the input and builds the inner
layer, which validates the input.

For clarity, we introduce the notion of a parser-validator: a parser that does
not consume any input, but may fail or use other effects. Thus we have:

  abParser :: P (PV A, PV B)

-}

{- Note [Parser-Validator Hint]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A PV computation is parametrized by a hint for error messages, which can be set
depending on validation context. We use this in checkPattern to fix #984.

Consider this example, where the user has forgotten a 'do':

  f _ = do
    x <- computation
    case () of
      _ ->
        result <- computation
        case () of () -> undefined

GHC parses it as follows:

  f _ = do
    x <- computation
    (case () of
      _ ->
        result) <- computation
        case () of () -> undefined

Note that this fragment is parsed as a pattern:

  case () of
    _ ->
      result

We attempt to detect such cases and add a hint to the error messages:

  T984.hs:6:9:
    Parse error in pattern: case () of { _ -> result }
    Possibly caused by a missing 'do'?

The "Possibly caused by a missing 'do'?" suggestion is the hint that is passed
as the 'pv_hint' field 'PV_Context'. When validating in a context other than
'bindpat' (a pattern to the left of <-), we set the hint to 'empty' and it has
no effect on the error messages.

-}

-- | Hint about bang patterns, assuming @BangPatterns@ is off.
hintBangPat :: SrcSpan -> Pat GhcPs -> PV ()
hintBangPat span e = do
    bang_on <- getBit BangPatBit
    unless bang_on $
      addError span
        (text "Illegal bang-pattern (use BangPatterns):" $$ ppr e)

data SumOrTuple b
  = Sum ConTag Arity (LocatedA b)
  | Tuple [LocatedA (Maybe (LocatedA b))]

pprSumOrTuple :: Outputable b => Boxity -> SumOrTuple b -> SDoc
pprSumOrTuple boxity = \case
    Sum alt arity e ->
      parOpen <+> ppr_bars (alt - 1) <+> ppr e <+> ppr_bars (arity - alt)
              <+> parClose
    Tuple xs ->
      parOpen <> (fcat . punctuate comma $ map (maybe empty ppr . unLoc) xs)
              <> parClose
  where
    ppr_bars n = hsep (replicate n (Outputable.char '|'))
    (parOpen, parClose) =
      case boxity of
        Boxed -> (text "(", text ")")
        Unboxed -> (text "(#", text "#)")

mkSumOrTupleExpr :: SrcSpanAnnA -> Boxity -> SumOrTuple (HsExpr GhcPs)
                 -> [AddApiAnn]
                 -> PV (LHsExpr GhcPs)

-- Tuple
mkSumOrTupleExpr l boxity (Tuple es) anns = do
    cs <- addAnnsAt (locA l) []
    return $ L l (ExplicitTuple (ApiAnn (realSrcSpan $ locA l) anns cs) (map toTupArg es) boxity)
  where
    toTupArg :: LocatedA (Maybe (LHsExpr GhcPs)) -> LHsTupArg GhcPs
    toTupArg = mapLoc (maybe missingTupArg (Present noExtField))

-- Sum
mkSumOrTupleExpr l Unboxed (Sum alt arity e) anns = do
    cs <- addAnnsAt (locA l) []
    return $ L l (ExplicitSum (ApiAnn (realSrcSpan $ locA l) anns cs) alt arity e)
mkSumOrTupleExpr l Boxed a@Sum{} _ =
    addFatalError (locA l) (hang (text "Boxed sums not supported:") 2
                      (pprSumOrTuple Boxed a))

mkSumOrTuplePat
  :: SrcSpanAnnA -> Boxity -> SumOrTuple (PatBuilder GhcPs) -> [AddApiAnn]
  -> PV (LocatedA (PatBuilder GhcPs))

-- Tuple
mkSumOrTuplePat l boxity (Tuple ps) anns = do
  ps' <- traverse toTupPat ps
  cs <- addAnnsAt (locA l) []
  return $ L l (PatBuilderPat (TuplePat (ApiAnn (realSrcSpan $ locA l) anns cs) ps' boxity))
  where
    toTupPat :: LocatedA (Maybe (LocatedA (PatBuilder GhcPs))) -> PV (LPat GhcPs)
    toTupPat (L l p) = case p of
      Nothing -> addFatalError (locA l) (text "Tuple section in pattern context")
      Just p' -> checkLPat p'

-- Sum
mkSumOrTuplePat l Unboxed (Sum alt arity p) anns = do
   p' <- checkLPat p
   cs <- addAnnsAt (locA l) []
   return $ L l (PatBuilderPat (SumPat (ApiAnn (realSrcSpan $ locA l) anns cs) p' alt arity))
mkSumOrTuplePat l Boxed a@Sum{} _ =
    addFatalError (locA l) (hang (text "Boxed sums not supported:") 2
                      (pprSumOrTuple Boxed a))

mkLHsOpTy :: LHsType GhcPs -> LocatedN RdrName -> LHsType GhcPs -> LHsType GhcPs
mkLHsOpTy x op y =
  let loc = getLoc x `combineSrcSpansA` (noAnnSrcSpan $ getLocA op) `combineSrcSpansA` getLoc y
  in L loc (mkHsOpTy x op y)

mkLHsDocTy :: LHsType GhcPs -> LHsDocString -> LHsType GhcPs
mkLHsDocTy t doc =
  let loc = getLoc t `combineSrcSpansA` (noAnnSrcSpan $ getLoc doc)
  in L loc (HsDocTy noAnn t doc) -- AZ:TODO anns

mkLHsDocTyMaybe :: LHsType GhcPs -> Maybe LHsDocString -> LHsType GhcPs
mkLHsDocTyMaybe t = maybe t (mkLHsDocTy t)

-----------------------------------------------------------------------------
-- Token symbols

starSym :: Bool -> String
starSym True = "★"
starSym False = "*"

forallSym :: Bool -> String
forallSym True = "∀"
forallSym False = "forall"
