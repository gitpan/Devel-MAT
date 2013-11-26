/*  You may distribute under the terms of either the GNU General Public License
 *  or the Artistic License (the same terms as Perl itself)
 *
 *  (C) Paul Evans, 2013 -- leonerd@leonerd.org.uk
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#define FORMAT_VERSION 0

#ifndef SvOOK_offset
#  define SvOOK_offset(sv, len) STMT_START { len = SvIVX(sv); } STMT_END
#endif

static int max_string;

// These do NOT agree with perl's SVt_* constants!
enum PMAT_SVt {
  PMAT_SVtGLOB = 1,
  PMAT_SVtSCALAR,
  PMAT_SVtARRAY,
  PMAT_SVtHASH,
  PMAT_SVtSTASH,
  PMAT_SVtCODE,
  PMAT_SVtIO,
  PMAT_SVtLVALUE,
  PMAT_SVtREGEXP,
  PMAT_SVtFORMAT,
  PMAT_SVtINVLIST,

  PMAT_SVtMAGIC = 0x80,
};

enum PMAT_CODEx {
  PMAT_CODEx_CONSTSV = 1,
  PMAT_CODEx_CONSTIX,
  PMAT_CODEx_GVSV,
  PMAT_CODEx_GVIX,
  PMAT_CODEx_PADNAME,
  PMAT_CODEx_PADSV,
  PMAT_CODEx_PADNAMES,
  PMAT_CODEx_PAD,
};

static void write_u8(FILE *fh, uint8_t v)
{
  fwrite(&v, 1, 1, fh);
}

/* We just write multi-byte integers in native endian, because we've declared
 * in the file flags what the platform byte direction is anyway
 */
static void write_u32(FILE *fh, uint32_t v)
{
  fwrite(&v, 4, 1, fh);
}

static void write_u64(FILE *fh, uint64_t v)
{
  fwrite(&v, 8, 1, fh);
}

static void write_uint(FILE *fh, UV v)
{
#if UVSIZE == 8
  write_u64(fh, v);
#elif UVSIZE == 4
  write_u32(fh, v);
#else
# error "Expected UVSIZE to be either 4 or 8"
#endif
}

static void write_svptr(FILE *fh, const SV *ptr)
{
  fwrite(&ptr, sizeof ptr, 1, fh);
}

static void write_nv(FILE *fh, NV v)
{
#if NVSIZE == 8
  fwrite(&v, sizeof(NV), 1, fh);
#else
  // long double is 10 bytes but sizeof() may be 16.
  fwrite(&v, 10, 1, fh);
#endif
}

static void write_strn(FILE *fh, const char *s, size_t len)
{
  write_uint(fh, len);
  fwrite(s, len, 1, fh);
}

static void write_str(FILE *fh, const char *s)
{
  if(s)
    write_strn(fh, s, strlen(s));
  else
    write_uint(fh, -1);
}

static void dump_optree(FILE *fh, const CV *cv, OP *o);
static void dump_optree(FILE *fh, const CV *cv, OP *o)
{
  switch(o->op_type) {
    case OP_CONST:
    case OP_METHOD_NAMED:
#ifdef USE_ITHREADS
      if(o->op_targ) {
        write_u8(fh, PMAT_CODEx_CONSTIX);
        write_uint(fh, o->op_targ);
      }
#else
      write_u8(fh, PMAT_CODEx_CONSTSV);
      write_svptr(fh, cSVOPx(o)->op_sv);
#endif
      break;

    case OP_AELEMFAST:
    case OP_GVSV:
    case OP_GV:
#ifdef USE_ITHREADS
      write_u8(fh, PMAT_CODEx_GVIX);
      write_uint(fh, o->op_targ);
#else
      write_u8(fh, PMAT_CODEx_GVSV);
      write_svptr(fh, cSVOPx(o)->op_sv);
#endif
      break;
  }

  if(o->op_flags & OPf_KIDS) {
    OP *kid;
    for (kid = ((UNOP*)o)->op_first; kid; kid = kid->op_sibling) {
      dump_optree(fh, cv, kid);
    }
  }
}

static void write_common_sv(FILE *fh, const SV *sv, size_t size)
{
  write_svptr(fh, sv);
  write_u32(fh, SvREFCNT(sv));
  write_svptr(fh, SvOBJECT(sv) ? (SV*)SvSTASH(sv) : NULL);
  write_uint(fh, sizeof(SV) + size);
}

static void write_private_gv(FILE *fh, const GV *gv)
{
  write_common_sv(fh, (const SV *)gv,
    sizeof(XPVGV) + (isGV_with_GP(gv) ? sizeof(struct gp) : 0));

  if(isGV_with_GP(gv)) {
    write_str(fh, GvNAME(gv));
    write_str(fh, GvFILE(gv));
    write_uint(fh, GvLINE(gv));
    write_svptr(fh, (SV*)GvSTASH(gv));
    write_svptr(fh,      GvSV(gv));
    write_svptr(fh, (SV*)GvAV(gv));
    write_svptr(fh, (SV*)GvHV(gv));
    write_svptr(fh, (SV*)GvCV(gv));
    write_svptr(fh, (SV*)GvEGV(gv));
    write_svptr(fh, (SV*)GvIO(gv));
    write_svptr(fh, (SV*)GvFORM(gv));
  }
  else {
    write_str(fh, NULL);
    write_str(fh, NULL);
    write_uint(fh, 0);
    write_svptr(fh, (SV*)GvSTASH(gv));
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
  }
}

static void write_private_sv(FILE *fh, const SV *sv)
{
  size_t size = 0;
  switch(SvTYPE(sv)) {
    case SVt_IV: break;
    case SVt_NV:   size += sizeof(NV); break;
#if (PERL_REVISION == 5) && (PERL_VERSION < 12)
    case SVt_RV: break;
#endif
    case SVt_PV:   size += sizeof(XPV) - STRUCT_OFFSET(XPV, xpv_cur); break;
    case SVt_PVIV: size += sizeof(XPVIV) - STRUCT_OFFSET(XPV, xpv_cur); break;
    case SVt_PVNV: size += sizeof(XPVNV) - STRUCT_OFFSET(XPV, xpv_cur); break;
    case SVt_PVMG: size += sizeof(XPVMG); break;
  }

  if(SvPOK(sv))
    size += SvLEN(sv);
  if(SvOOK(sv)) {
    STRLEN offset;
    SvOOK_offset(sv, offset);
    size += offset;
  }

  write_common_sv(fh, sv, size);

  write_u8(fh, (SvIOK(sv) ? 0x01 : 0) |
               (SvUOK(sv) ? 0x02 : 0) |
               (SvNOK(sv) ? 0x04 : 0) |
               (SvPOK(sv) ? 0x08 : 0) |
               (SvROK(sv) ? 0x10 : 0) |
               (SvWEAKREF(sv) ? 0x20 : 0));
  if(SvIOK(sv))
    write_uint(fh, SvUVX(sv));
  if(SvNOK(sv))
    write_nv(fh, SvNVX(sv));
  if(SvPOK(sv)) {
    write_uint(fh, SvCUR(sv));
    STRLEN len = SvCUR(sv);
    if(max_string > -1 && len > max_string)
      len = max_string;
    write_strn(fh, SvPVX(sv), len);
  }
  if(SvROK(sv))
    write_svptr(fh, SvRV(sv));
}

static void write_private_av(FILE *fh, const AV *av)
{
  int len = AvFILLp(av) + 1;

  write_common_sv(fh, (const SV *)av,
    sizeof(XPVAV) + sizeof(SV *) * len);

  write_uint(fh, len);
  int i;
  for(i = 0; i < len; i++)
    write_svptr(fh, AvARRAY(av)[i]);
}

static void write_private_hv(FILE *fh, const HV *hv, size_t size)
{
  size += sizeof(XPVHV);
  int nkeys = 0;

  if(HvARRAY(hv)) {
    int bucket;
    for(bucket = 0; bucket <= HvMAX(hv); bucket++) {
      HE *he;
      size += sizeof(HE *);

      for(he = HvARRAY(hv)[bucket]; he; he = he->hent_next) {
        size += sizeof(HE);
        nkeys++;

        if(!HvSHAREKEYS(hv))
          size += sizeof(HEK) + he->hent_hek->hek_len + 2;
      }
    }
  }

  write_common_sv(fh, (const SV *)hv, size);

  if(SvOOK(hv) && HvAUX(hv))
    write_svptr(fh, (SV*)HvAUX(hv)->xhv_backreferences);
  else
    write_svptr(fh, NULL);

  // The shared string table (PL_strtab) has shared strings as keys but its
  // values are not SV pointers; they are refcounts.
  if(hv == PL_strtab) {
    write_uint(fh, 0);
    return;
  }

  write_uint(fh, nkeys);

  if(HvARRAY(hv)) {
    int bucket;
    for(bucket = 0; bucket <= HvMAX(hv); bucket++) {
      HE *he;
      for(he = HvARRAY(hv)[bucket]; he; he = he->hent_next) {
        STRLEN len;
        char *key = HePV(he, len);
        write_strn(fh, key, len);
        write_svptr(fh, HeVAL(he));
      }
    }
  }
}

static void write_private_stash(FILE *fh, const HV *stash)
{
  struct mro_meta *mro_meta = HvAUX(stash)->xhv_mro_meta;

  write_private_hv(fh, stash,
    sizeof(struct xpvhv_aux) + (mro_meta ? sizeof(struct mro_meta) : 0));

  write_str(fh, HvNAME(stash));

  if(mro_meta) {
#if (PERL_REVISION == 5) && (PERL_VERSION >= 12)
    write_svptr(fh, (SV*)mro_meta->mro_linear_all);
    write_svptr(fh,      mro_meta->mro_linear_current);
#else
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
#endif
    write_svptr(fh, (SV*)mro_meta->mro_nextmethod);
#if (PERL_REVISION == 5) && ((PERL_VERSION > 10) || (PERL_VERSION == 10 && PERL_SUBVERSION > 0))
    write_svptr(fh, (SV*)mro_meta->isa);
#else
    write_svptr(fh, NULL);
#endif
  }
  else {
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
    write_svptr(fh, NULL);
  }
}

static void write_private_cv(FILE *fh, const CV *cv)
{
  PADLIST *padlist;

  // TODO: accurate size information on CVs
  write_common_sv(fh, (const SV *)cv, sizeof(XPVCV));

  write_svptr(fh, (SV*)CvSTASH(cv));
  write_svptr(fh, (SV*)CvGV(cv));
  if(CvFILE(cv))
    write_str(fh, CvFILE(cv));
  else
    write_str(fh, "");

  int line = 0;
  OP *start;
  if(!CvISXSUB(cv) && !CvCONST(cv) && (start = CvSTART(cv))) {
    if(start->op_type == OP_NEXTSTATE)
      line = CopLINE((COP*)start);
  }
  write_uint(fh, line);

  write_svptr(fh, (SV*)CvOUTSIDE(cv));
  write_svptr(fh, (SV*)(padlist = CvPADLIST(cv)));
  if(CvCONST(cv))
    write_svptr(fh, (SV*)CvXSUBANY(cv).any_ptr);
  else
    write_svptr(fh, NULL);

  if(cv == PL_main_cv)
    /* The PL_main_cv does not have a CvROOT(); instead that is found in
     * PL_main_root
     */
    dump_optree(fh, cv, PL_main_root);
  else if(!CvISXSUB(cv) && !CvCONST(cv) && CvROOT(cv))
    dump_optree(fh, cv, CvROOT(cv));

#if (PERL_REVISION == 5) && (PERL_VERSION >= 18)
  if(padlist) {
    PADNAME **names = PadlistNAMESARRAY(padlist);
    PAD **pads = PadlistARRAY(padlist);
    int depth, i;

    write_u8(fh, PMAT_CODEx_PADNAMES);
    write_svptr(fh, (SV*)PadlistNAMES(padlist));

    for(i = 0; i <= PadlistNAMESMAX(padlist); i++) {
      write_u8(fh, PMAT_CODEx_PADNAME);
      write_uint(fh, i);
      if(names[i] && PadnamePV(names[i]))
        write_str(fh, PadnamePV(names[i]));
      else
        write_uint(fh, -1);
    }

    for(depth = 1; depth <= PadlistMAX(padlist); depth++) {
      PAD *pad = pads[depth];
      SV **svs = PadARRAY(pad);

      write_u8(fh, PMAT_CODEx_PAD);
      write_uint(fh, depth);
      write_svptr(fh, (SV*)pad);

      for(i = 1; i <= PadMAX(pad); i++) {
        write_u8(fh, PMAT_CODEx_PADSV);
        write_uint(fh, depth);
        write_uint(fh, i);
        write_svptr(fh, svs[i]);
      }
    }
  }
#endif

  write_u8(fh, 0);
}

static void write_private_io(FILE *fh, const IO *io)
{
  write_common_sv(fh, (const SV *)io, sizeof(XPVIO));

  write_svptr(fh, (SV*)IoTOP_GV(io));
  write_svptr(fh, (SV*)IoFMT_GV(io));
  write_svptr(fh, (SV*)IoBOTTOM_GV(io));
}

static void write_private_lv(FILE *fh, const SV *sv)
{
  write_common_sv(fh, sv, sizeof(XPVLV));

  write_u8(fh, LvTYPE(sv));
  write_uint(fh, LvTARGOFF(sv));
  write_uint(fh, LvTARGLEN(sv));
  write_svptr(fh, LvTARG(sv));
}

static void write_sv(FILE *fh, const SV *sv)
{
  unsigned char type = -1;
  switch(SvTYPE(sv)) {
    case SVt_IV:
    case SVt_NV:
#if (PERL_REVISION == 5) && (PERL_VERSION < 12)
    case SVt_RV:
#endif
    case SVt_PV:
    case SVt_PVIV:
    case SVt_PVNV:
    case SVt_PVMG:
      type = PMAT_SVtSCALAR; break;
#if (PERL_REVISION == 5) && (PERL_VERSION >= 19)
    case SVt_INVLIST: type = PMAT_SVtINVLIST; break;
#endif
#if (PERL_REVISION == 5) && (PERL_VERSION >= 12)
    case SVt_REGEXP: type = PMAT_SVtREGEXP; break;
#endif
    case SVt_PVGV: type = PMAT_SVtGLOB; break;
    case SVt_PVLV: type = PMAT_SVtLVALUE; break;
    case SVt_PVAV: type = PMAT_SVtARRAY; break;
    // HVs with names we call STASHes
    case SVt_PVHV: type = HvNAME(sv) ? PMAT_SVtSTASH : PMAT_SVtHASH; break;
    case SVt_PVCV: type = PMAT_SVtCODE; break;
    case SVt_PVFM: type = PMAT_SVtFORMAT; break;
    case SVt_PVIO: type = PMAT_SVtIO; break;
    default:
      fprintf(stderr, "dumpsv %p has unknown SvTYPE %d\n", sv, SvTYPE(sv));
      break;
  }

  write_u8(fh, type);

  switch(type) {
    case PMAT_SVtGLOB:   write_private_gv   (fh, (GV*)sv); break;
    case PMAT_SVtSCALAR: write_private_sv   (fh,      sv); break;
    case PMAT_SVtARRAY:  write_private_av   (fh, (AV*)sv); break;
    case PMAT_SVtHASH:   write_private_hv   (fh, (HV*)sv, 0); break;
    case PMAT_SVtSTASH:  write_private_stash(fh, (HV*)sv); break;
    case PMAT_SVtCODE:   write_private_cv   (fh, (CV*)sv); break;
    case PMAT_SVtIO:     write_private_io   (fh, (IO*)sv); break;
    case PMAT_SVtLVALUE: write_private_lv   (fh,      sv); break;

#if (PERL_REVISION == 5) && (PERL_VERSION >= 12)
    case PMAT_SVtREGEXP: write_common_sv(fh, sv, sizeof(regexp)); break;
#endif
    case PMAT_SVtFORMAT: write_common_sv(fh, sv, sizeof(XPVFM)); break;
    case PMAT_SVtINVLIST: write_common_sv(fh, sv, sizeof(XPV) + SvLEN(sv)); break;
  }

  if(SvMAGICAL(sv)) {
    MAGIC *mg;
    for(mg = SvMAGIC(sv); mg; mg = mg->mg_moremagic) {
      if(mg->mg_flags & MGf_REFCOUNTED) {
        write_u8(fh, PMAT_SVtMAGIC);
        write_svptr(fh, sv);
        write_svptr(fh, mg->mg_obj);
        write_u8(fh, mg->mg_type);
      }

      if(mg->mg_len == HEf_SVKEY) {
        write_u8(fh, PMAT_SVtMAGIC);
        write_svptr(fh, sv);
        write_svptr(fh, (SV*)mg->mg_ptr);
        write_u8(fh, mg->mg_type);
      }
    }
  }
}

static void dumpfh(FILE *fh)
{
  // Header
  fwrite("PMAT", 4, 1, fh);

  int flags = 0;
#if (BYTEORDER == 0x1234) || (BYTEORDER == 0x12345678)
  // little-endian
#elif (BYTEORDER == 0x4321) || (BYTEORDER == 0x87654321)
  flags |= 0x01; // big-endian
#else
# error "Expected BYTEORDER to be big- or little-endian"
#endif

#if UVSIZE == 8
  flags |= 0x02; // 64-bit integers
#elif UVSIZE == 4
#else
# error "Expected UVSIZE to be either 4 or 8"
#endif

#if PTRSIZE == 8
  flags |= 0x04; // 64-bit pointers
#elif PTRSIZE == 4
#else
# error "Expected PTRSIZE to be either 4 or 8"
#endif

#if NVSIZE == 10 || NVSIZE == 16
  flags |= 0x08; // long-double
#elif NVSIZE == 8
#else
# error "Expected NVSIZE to be either 8, 10 or 16"
#endif

#ifdef USE_ITHREADS
  flags |= 0x10; // ithreads
#endif

  write_u8(fh, flags);
  write_u8(fh, 0);
  write_u8(fh, FORMAT_VERSION >> 8); write_u8(fh, FORMAT_VERSION & 0xff);

  write_u32(fh, PERL_REVISION<<24 | PERL_VERSION<<16 | PERL_SUBVERSION);

  // Roots
  write_svptr(fh, &PL_sv_undef);
  write_svptr(fh, &PL_sv_yes);
  write_svptr(fh, &PL_sv_no);

  struct root { char *name; SV *ptr; } roots[] = {
    { "main_cv",         (SV*)PL_main_cv },
    { "defstash",        (SV*)PL_defstash },
    { "mainstack",       (SV*)PL_mainstack },
    { "beginav",         (SV*)PL_beginav },
    { "checkav",         (SV*)PL_checkav },
    { "unitcheckav",     (SV*)PL_unitcheckav },
    { "initav",          (SV*)PL_initav },
    { "endav",           (SV*)PL_endav },
    { "strtab",          (SV*)PL_strtab },
    { "envgv",           (SV*)PL_envgv },
    { "incgv",           (SV*)PL_incgv },
    { "statgv",          (SV*)PL_statgv },
    { "statname",        (SV*)PL_statname },
    { "tmpsv",           (SV*)PL_Sv }, // renamed
    { "defgv",           (SV*)PL_defgv },
    { "argvgv",          (SV*)PL_argvgv },
    { "argvoutgv",       (SV*)PL_argvoutgv },
    { "argvout_stack",   (SV*)PL_argvout_stack },
    { "fdpid",           (SV*)PL_fdpid },
    { "preambleav",      (SV*)PL_preambleav },
    { "modglobalhv",     (SV*)PL_modglobal },
#ifdef USE_ITHREADS
    { "regex_padav",     (SV*)PL_regex_padav },
#endif
    { "sortstash",       (SV*)PL_sortstash },
    { "firstgv",         (SV*)PL_firstgv },
    { "secondgv",        (SV*)PL_secondgv },
    { "debstash",        (SV*)PL_debstash },
    { "stashcache",      (SV*)PL_stashcache },
    { "isarev",          (SV*)PL_isarev },
#if (PERL_REVISION == 5) && ((PERL_VERSION > 10) || (PERL_VERSION == 10 && PERL_SUBVERSION > 0))
    { "registered_mros", (SV*)PL_registered_mros },
#endif
    { "rs",              (SV*)PL_rs },
    { "last_in_gv",      (SV*)PL_last_in_gv },
    { "defoutgv",        (SV*)PL_defoutgv },
    { "hintgv",          (SV*)PL_hintgv },
    { "patchlevel",      (SV*)PL_patchlevel },
    { "e_script",        (SV*)PL_e_script },
    { "mess_sv",         (SV*)PL_mess_sv },
    { "ors_sv",          (SV*)PL_ors_sv },
    { "encoding",        (SV*)PL_encoding },
#if (PERL_REVISION == 5) && (PERL_VERSION >= 12)
    { "ofsgv",           (SV*)PL_ofsgv },
#endif
#if (PERL_REVISION == 5) && (PERL_VERSION >= 14)
    { "apiversion",      (SV*)PL_apiversion },
    { "blockhooks",      (SV*)PL_blockhooks },
#endif
#if (PERL_REVISION == 5) && (PERL_VERSION >= 16)
    { "custom_ops",      (SV*)PL_custom_ops },
    { "custom_op_names", (SV*)PL_custom_op_names },
    { "custom_op_descs", (SV*)PL_custom_op_descs },
#endif

    // Unicode etc...
    { "utf8_mark",              (SV*)PL_utf8_mark },
    { "utf8_toupper",           (SV*)PL_utf8_toupper },
    { "utf8_totitle",           (SV*)PL_utf8_totitle },
    { "utf8_tolower",           (SV*)PL_utf8_tolower },
    { "utf8_tofold",            (SV*)PL_utf8_tofold },
    { "utf8_idstart",           (SV*)PL_utf8_idstart },
    { "utf8_idcont",            (SV*)PL_utf8_idcont },
#if (PERL_REVISION == 5) && (PERL_VERSION >= 12)
    { "utf8_X_extend",          (SV*)PL_utf8_X_extend },
#endif
#if (PERL_REVISION == 5) && (PERL_VERSION >= 14)
    { "utf8_xidstart",          (SV*)PL_utf8_xidstart },
    { "utf8_xidcont",           (SV*)PL_utf8_xidcont },
    { "utf8_foldclosures",      (SV*)PL_utf8_foldclosures },
    { "utf8_foldable",          (SV*)PL_utf8_foldable },
#endif
#if (PERL_REVISION == 5) && (PERL_VERSION >= 16)
    { "Latin1",                 (SV*)PL_Latin1 },
    { "AboveLatin1",            (SV*)PL_AboveLatin1 },
    { "utf8_perl_idstart",      (SV*)PL_utf8_perl_idstart },
#endif
#if (PERL_REVISION == 5) && (PERL_VERSION >= 18)
    { "NonL1NonFinalFold",      (SV*)PL_NonL1NonFinalFold },
    { "HasMultiCharFold",       (SV*)PL_HasMultiCharFold },
    { "utf8_X_regular_begin",   (SV*)PL_utf8_X_regular_begin },
    { "utf8_charname_begin",    (SV*)PL_utf8_charname_begin },
    { "utf8_charname_continue", (SV*)PL_utf8_charname_continue },
    { "utf8_perl_idcont",       (SV*)PL_utf8_perl_idcont },
#endif
#if (PERL_REVISION == 5) && ((PERL_VERSION > 19) || (PERL_VERSION == 19 && PERL_SUBVERSION >= 4))
    { "UpperLatin1",            (SV*)PL_UpperLatin1 },
#endif
  };

  write_u32(fh, sizeof(roots) / sizeof(roots[0]));

  int i;
  for(i = 0; i < sizeof(roots) / sizeof(roots[0]); i++) {
    write_str(fh, roots[i].name);
    write_svptr(fh, roots[i].ptr);
  }

  // Stack
  write_uint(fh, PL_stack_sp - PL_stack_base + 1);
  SV **sp;
  for(sp = PL_stack_base; sp <= PL_stack_sp; sp++)
    write_svptr(fh, *sp);

  // Heap
  SV *arena;
  for(arena = PL_sv_arenaroot; arena; arena = (SV *)SvANY(arena)) {
    const SV *arenaend = &arena[SvREFCNT(arena)];

    SV *sv;
    for(sv = arena + 1; sv < arenaend; sv++) {
      switch(SvTYPE(sv)) {
        case 0:
        case 0xff:
          continue;
      }

      write_sv(fh, sv);
    }
  }

  // and a few other things that don't actually appear in the arena
  write_sv(fh, (const SV *)PL_defstash); 

  write_u8(fh, 0);
}

static void dump(char *file)
{
  FILE *fh = fopen(file, "wb+");
  if(!fh)
    croak("Cannot open %s for writing - %s", file, strerror(errno));

  max_string = SvIV(get_sv("Devel::MAT::Dumper::MAX_STRING", GV_ADD));

  dumpfh(fh);
  fclose(fh);
}

MODULE = Devel::MAT::Dumper        PACKAGE = Devel::MAT::Dumper

void
dump(char *file)
