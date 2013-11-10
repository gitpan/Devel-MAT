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

static void write_ptr(FILE *fh, const void *ptr)
{
  fwrite(&ptr, sizeof ptr, 1, fh);
}

static void write_nv(FILE *fh, NV v)
{
#if NVSIZE == 8
  fwrite(&v, sizeof(double), 1, fh);
#else
  fwrite(&v, sizeof(long double), 1, fh);
#endif
}

static void write_strn(FILE *fh, const char *s, size_t len)
{
  write_uint(fh, len);
  fwrite(s, len, 1, fh);
}

static void write_str(FILE *fh, const char *s)
{
  write_strn(fh, s, strlen(s));
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
      write_ptr(fh, cSVOPx(o)->op_sv);
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
      write_ptr(fh, cSVOPx(o)->op_sv);
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

static void write_private_gv(FILE *fh, const GV *gv)
{
  write_str(fh, GvNAME(gv));
  write_ptr(fh, GvSTASH(gv));
  write_ptr(fh, GvSV(gv));
  write_ptr(fh, GvAV(gv));
  write_ptr(fh, GvHV(gv));
  write_ptr(fh, GvCV(gv));
  write_ptr(fh, GvEGV(gv));
  write_ptr(fh, GvIO(gv));
  write_ptr(fh, GvFORM(gv));
}

static void write_private_sv(FILE *fh, const SV *sv)
{
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
  if(SvPOK(sv))
    write_strn(fh, SvPVX(sv), SvCUR(sv));
  if(SvROK(sv))
    write_ptr(fh, SvRV(sv));
}

static void write_private_av(FILE *fh, const AV *av)
{
  int len = AvFILLp(av) + 1;
  write_uint(fh, len);
  int i;
  for(i = 0; i < len; i++)
    write_ptr(fh, AvARRAY(av)[i]);
}

static void write_private_hv(FILE *fh, const HV *hv)
{
  if(SvOOK(hv) && HvAUX(hv))
    write_ptr(fh, HvAUX(hv)->xhv_backreferences);
  else
    write_ptr(fh, NULL);

  if(hv_iterinit((HV *)hv)) {
    HE *he;
    int nkeys = 0;
    while((he = hv_iternext((HV *)hv)))
      nkeys++;

    write_uint(fh, nkeys);

    hv_iterinit((HV *)hv);
    while((he = hv_iternext((HV *)hv))) {
      STRLEN len;
      char *key = HePV(he, len);
      write_strn(fh, key, len);
      write_ptr(fh, HeVAL(he));
    }
  }
  else {
    write_uint(fh, 0);
  }
}

static void write_private_stash(FILE *fh, const HV *stash)
{
  struct mro_meta *mro_meta = HvAUX(stash)->xhv_mro_meta;

  write_str(fh, HvNAME(stash));

  if(mro_meta) {
#if (PERL_REVISION == 5) && (PERL_VERSION >= 12)
    write_ptr(fh, mro_meta->mro_linear_all);
    write_ptr(fh, mro_meta->mro_linear_current);
#else
    write_ptr(fh, NULL);
    write_ptr(fh, NULL);
#endif
    write_ptr(fh, mro_meta->mro_nextmethod);
#if (PERL_REVISION == 5) && ((PERL_VERSION > 10) || (PERL_VERSION == 10 && PERL_SUBVERSION > 0))
    write_ptr(fh, mro_meta->isa);
#else
    write_ptr(fh, NULL);
#endif
  }
  else {
    write_ptr(fh, NULL);
    write_ptr(fh, NULL);
    write_ptr(fh, NULL);
    write_ptr(fh, NULL);
  }

  write_private_hv(fh, stash);
}

static void write_private_cv(FILE *fh, const CV *cv)
{
  PADLIST *padlist;

  write_ptr(fh, CvSTASH(cv));
  write_ptr(fh, CvGV(cv));
  if(CvFILE(cv))
    write_str(fh, CvFILE(cv));
  else
    write_str(fh, "");
  write_ptr(fh, CvOUTSIDE(cv));
  write_ptr(fh, padlist = CvPADLIST(cv));
  if(CvCONST(cv))
    write_ptr(fh, (SV *)CvXSUBANY(cv).any_ptr);
  else
    write_ptr(fh, NULL);

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
    write_ptr(fh, PadlistNAMES(padlist));

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
      write_ptr(fh, pad);

      for(i = 1; i <= PadMAX(pad); i++) {
        write_u8(fh, PMAT_CODEx_PADSV);
        write_uint(fh, depth);
        write_uint(fh, i);
        write_ptr(fh, svs[i]);
      }
    }
  }
#endif

  write_u8(fh, 0);
}

static void write_private_io(FILE *fh, const IO *io)
{
  write_ptr(fh, IoTOP_GV(io));
  write_ptr(fh, IoFMT_GV(io));
  write_ptr(fh, IoBOTTOM_GV(io));
}

static void write_private_lv(FILE *fh, const SV *sv)
{
  write_u8(fh, LvTYPE(sv));
  write_uint(fh, LvTARGOFF(sv));
  write_uint(fh, LvTARGLEN(sv));
  write_ptr(fh, LvTARG(sv));
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
  write_ptr(fh, sv);
  write_u32(fh, SvREFCNT(sv));
  write_ptr(fh, SvOBJECT(sv) ? SvSTASH(sv) : 0);

  switch(type) {
    case PMAT_SVtGLOB:   write_private_gv   (fh, (GV*)sv); break;
    case PMAT_SVtSCALAR: write_private_sv   (fh,      sv); break;
    case PMAT_SVtARRAY:  write_private_av   (fh, (AV*)sv); break;
    case PMAT_SVtHASH:   write_private_hv   (fh, (HV*)sv); break;
    case PMAT_SVtSTASH:  write_private_stash(fh, (HV*)sv); break;
    case PMAT_SVtCODE:   write_private_cv   (fh, (CV*)sv); break;
    case PMAT_SVtIO:     write_private_io   (fh, (IO*)sv); break;
    case PMAT_SVtLVALUE: write_private_lv   (fh,      sv); break;

    case PMAT_SVtREGEXP:
    case PMAT_SVtFORMAT:
    case PMAT_SVtINVLIST:
      // nothing special
      break;
  }

  if(SvMAGICAL(sv)) {
    MAGIC *mg;
    for(mg = SvMAGIC(sv); mg; mg = mg->mg_moremagic) {
      if(mg->mg_flags & MGf_REFCOUNTED) {
        write_u8(fh, PMAT_SVtMAGIC);
        write_ptr(fh, sv);
        write_ptr(fh, mg->mg_obj);
        write_u8(fh, mg->mg_type);
      }

      if(mg->mg_len == HEf_SVKEY) {
        write_u8(fh, PMAT_SVtMAGIC);
        write_ptr(fh, sv);
        write_ptr(fh, mg->mg_ptr);
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
  write_ptr(fh, &PL_sv_undef);
  write_ptr(fh, &PL_sv_yes);
  write_ptr(fh, &PL_sv_no);
  write_ptr(fh, PL_main_cv);
  write_ptr(fh, PL_defstash);
  write_ptr(fh, PL_mainstack);
  write_ptr(fh, PL_beginav);
  write_ptr(fh, PL_checkav);
  write_ptr(fh, PL_unitcheckav);
  write_ptr(fh, PL_initav);
  write_ptr(fh, PL_endav);
  write_ptr(fh, PL_strtab);
  write_ptr(fh, PL_envgv);
  write_ptr(fh, PL_incgv);
  write_ptr(fh, PL_statgv);
  write_ptr(fh, PL_statname);
  write_ptr(fh, PL_Sv);
  write_ptr(fh, PL_defgv);
  write_ptr(fh, PL_argvgv);
  write_ptr(fh, PL_argvoutgv);
  write_ptr(fh, PL_argvout_stack);
  write_ptr(fh, PL_fdpid);
  write_ptr(fh, PL_preambleav);
  write_ptr(fh, PL_modglobal);
#ifdef USE_ITHREADS
  write_ptr(fh, PL_regex_padav);
#else
  write_ptr(fh, NULL);
#endif
  write_ptr(fh, PL_sortstash);
  write_ptr(fh, PL_firstgv);
  write_ptr(fh, PL_secondgv);
  write_ptr(fh, PL_debstash);
  write_ptr(fh, PL_stashcache);
  write_ptr(fh, PL_isarev);
#if (PERL_REVISION == 5) && ((PERL_VERSION > 10) || (PERL_VERSION == 10 && PERL_SUBVERSION > 0))
  write_ptr(fh, PL_registered_mros);
#else
  write_ptr(fh, NULL);
#endif

  // Stack
  write_uint(fh, PL_stack_sp - PL_stack_base + 1);
  SV **sp;
  for(sp = PL_stack_base; sp <= PL_stack_sp; sp++)
    write_ptr(fh, *sp);

  // Heap
  SV *arena;
  for(arena = PL_sv_arenaroot; arena; arena = (SV *)SvANY(arena)) {
    const SV *arenaend = &arena[SvREFCNT(arena)];

    SV *sv;
    for(sv = arena + 1; sv < arenaend; sv++) {
      switch(SvTYPE(sv)) {
        case 0:
        case 0xff:
          continue; break;
        case SVt_PVGV:
          if(!isGV_with_GP(sv)) continue;
          break;
      }

      if(SvREFCNT(sv) == 0)
        continue;

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

  dumpfh(fh);
  fclose(fh);
}

MODULE = Devel::MAT::Dumper        PACKAGE = Devel::MAT::Dumper

void
dump(char *file)
