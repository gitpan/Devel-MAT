/*  You may distribute under the terms of either the GNU General Public License
 *  or the Artistic License (the same terms as Perl itself)
 *
 *  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

struct pmat_sv
{
  SV  *df;
  long addr;
  long refcnt;
  long size;
  long blessed_at;
  long glob_at;
};

/* Some subtypes */
struct pmat_sv_glob
{
  struct pmat_sv _parent;
  long           stash_at;
  long           scalar_at, array_at, hash_at, code_at, egv_at, io_at, form_at;
  long           line;
  const char    *file;
  const char    *name;
};

struct pmat_sv_scalar
{
  struct pmat_sv _parent;
  long           uv;
  long double    nv;
  char          *pv;
  size_t         pv_strlen; /* length of the pv member data */
  size_t         pvlen;     /* original PV length */
  long           ourstash_at;
  char           flags;
};

struct pmat_sv_ref
{
  struct pmat_sv _parent;
  long           rv_at;
  long           ourstash_at;
  char           is_weak;
};

struct pmat_sv_array
{
  struct pmat_sv _parent;
  int            flags;
  long           n_elems;
  long          *elems_at;
  long           padcv_at;
};

struct pmat_sv_hash
{
  struct pmat_sv _parent;
  long           backrefs_at;
  long           n_values;
  struct pmat_hval {
    const char    *key;
    size_t         klen;
    long           value;
  }             *values_at;
};

struct pmat_sv_code
{
  struct pmat_sv _parent;
  long           line;
  long           flags;
  long           oproot;
  long           stash_at, outside_at, padlist_at, constval_at;
  const char    *file;
  long           protosub_at;
  long           padnames_at;
};

#if (PERL_REVISION == 5) && (PERL_VERSION < 14)
static MAGIC *mg_findext(const SV *sv, int type, const MGVTBL *vtbl)
{
  MAGIC *mg;
  for(mg = SvMAGIC(sv); mg; mg = mg->mg_moremagic)
    if(mg->mg_type == type && mg->mg_virtual == vtbl)
      return mg;
  return NULL;
}
#endif

/* Empty magic just for identity purposes */
const MGVTBL vtbl = { 0 };

static struct pmat_sv *get_pmat_sv(HV *obj)
{
  MAGIC *mg = mg_findext((SV *)obj, PERL_MAGIC_ext, &vtbl);
  if(mg)
    return (struct pmat_sv *)mg->mg_ptr;
  else
    return NULL;
}

static void free_pmat_sv(struct pmat_sv *sv)
{
  SvREFCNT_dec(sv->df);
  Safefree(sv);
}

/* An HV mapping strings to SvIVs of their usage count
 */
static HV *strings;

static const char *save_string(const char *s, size_t len)
{
  if(!strings)
    strings = newHV();

  HE *ent = hv_fetch_ent(strings, sv_2mortal(newSVpv(s, len)), 1, 0);
  SV *count = HeVAL(ent);

  if(!SvIOK(count))
    sv_setuv(count, 0);

  /* incr usage count */
  sv_setuv(count, SvUV(count) + 1);

  return HeKEY(ent);;
}

static void drop_string(const char *s, size_t len)
{
  HE *ent = hv_fetch_ent(strings, sv_2mortal(newSVpv(s, len)), 0, 0);
  if(!ent)
    return;

  /* decr usage count */
  SV *count = HeVAL(ent);
  if(SvUV(count) > 1) {
    sv_setuv(count, SvUV(count) - 1);
    return;
  }

  hv_delete(strings, s, 0, G_DISCARD);
}

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV

void
_set_core_fields(self, type, df, addr, refcnt, size, blessed_at)
  HV   *self
  int   type
  SV   *df
  long  addr
  long  refcnt
  long  size
  long  blessed_at
CODE:
  {
    void *ptr;
    struct pmat_sv *sv;
    switch(type) {
      case 1: /* PMAT_SVtGLOB */
        Newx(ptr, 1, struct pmat_sv_glob); break;
      case 2: /* PMAT_SVtSCALAR */
        Newx(ptr, 1, struct pmat_sv_scalar); break;
      case 3: /* PMAT_SVtREF */
        Newx(ptr, 1, struct pmat_sv_ref); break;
      case 4: /* PMAT_SVtARRAY */
        Newx(ptr, 1, struct pmat_sv_array); break;
      case 5: /* PMAT_SVtHASH  fallthrough */
      case 6: /* PMAT_SVtSTASH */
        Newx(ptr, 1, struct pmat_sv_hash); break;
      case 7: /* PMAT_SVtCODE */
        Newx(ptr, 1, struct pmat_sv_code); break;
      default:
        Newx(ptr, 1, struct pmat_sv); break;
    }

    sv = ptr;

    sv->df         = newSVsv(df);
    sv->addr       = addr;
    sv->refcnt     = refcnt;
    sv->size       = size;
    sv->blessed_at = blessed_at;
    sv->glob_at    = 0;

    sv_rvweaken(sv->df);

    sv_magicext((SV *)self, NULL, PERL_MAGIC_ext, &vtbl, (char *)sv, 0);
  }

void DESTROY(self)
  HV   *self
CODE:
  {
    struct pmat_sv *sv = get_pmat_sv(self);
    free_pmat_sv(sv);
  }

void
_set_glob_at(self, glob_at)
  HV   *self
  long  glob_at
CODE:
  {
    struct pmat_sv *sv = get_pmat_sv(self);
    sv->glob_at = glob_at;
  }

SV *df(self)
  HV   *self
CODE:
  {
    struct pmat_sv *sv = get_pmat_sv(self);
    RETVAL = SvREFCNT_inc(sv->df); /* return it directly */
  }
OUTPUT:
  RETVAL

long addr(self)
  HV   *self
ALIAS:
  addr       = 0
  refcnt     = 1
  size       = 2
  blessed_at = 3
  glob_at    = 4
CODE:
  {
    struct pmat_sv *sv = get_pmat_sv(self);
    if(sv)
      switch(ix) {
        case 0: RETVAL = sv->addr;       break;
        case 1: RETVAL = sv->refcnt;     break;
        case 2: RETVAL = sv->size;       break;
        case 3: RETVAL = sv->blessed_at; break;
        case 4: RETVAL = sv->glob_at;    break;
      }
  }
OUTPUT:
  RETVAL

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV::GLOB

void
_set_glob_fields(self, stash_at, scalar_at, array_at, hash_at, code_at, egv_at, io_at, form_at, line, file, name)
  HV   *self
  long  stash_at
  long  scalar_at
  long  array_at
  long  hash_at
  long  code_at
  long  egv_at
  long  io_at
  long  form_at
  long  line
  SV   *file
  SV   *name
CODE:
  {
    struct pmat_sv_glob *gv = (struct pmat_sv_glob *)get_pmat_sv(self);

    gv->stash_at  = stash_at;
    gv->scalar_at = scalar_at;
    gv->array_at  = array_at;
    gv->hash_at   = hash_at;
    gv->code_at   = code_at;
    gv->egv_at    = egv_at;
    gv->io_at     = io_at;
    gv->form_at   = form_at;

    if(SvPOK(file))
      gv->file = save_string(SvPV_nolen(file), 0);
    else
      gv->file = NULL;

    gv->line = line;

    if(SvPOK(name))
      gv->name = savepv(SvPV_nolen(name));
    else
      gv->name = NULL;
  }

void DESTROY(self)
  HV   *self
CODE:
  {
    struct pmat_sv_glob *gv = (struct pmat_sv_glob *)get_pmat_sv(self);

    if(gv->file)
      drop_string(gv->file, 0);
    if(gv->name)
      Safefree(gv->name);

    free_pmat_sv((struct pmat_sv *)gv);
  }

long stash_at(self)
  HV   *self
ALIAS:
  stash_at  = 0
  scalar_at = 1
  array_at  = 2
  hash_at   = 3
  code_at   = 4
  egv_at    = 5
  io_at     = 6
  form_at   = 7
  line      = 8
CODE:
  {
    struct pmat_sv_glob *gv = (struct pmat_sv_glob *)get_pmat_sv(self);
    if(gv)
      switch(ix) {
        case 0: RETVAL = gv->stash_at;  break;
        case 1: RETVAL = gv->scalar_at; break;
        case 2: RETVAL = gv->array_at;  break;
        case 3: RETVAL = gv->hash_at;   break;
        case 4: RETVAL = gv->code_at;   break;
        case 5: RETVAL = gv->egv_at;    break;
        case 6: RETVAL = gv->io_at;     break;
        case 7: RETVAL = gv->form_at;   break;
        case 8: RETVAL = gv->line;      break;
      }
  }
OUTPUT:
  RETVAL

const char *
file(self)
  HV   *self
ALIAS:
  file = 0
  name = 1
CODE:
  {
    struct pmat_sv_glob *gv = (struct pmat_sv_glob *)get_pmat_sv(self);
    if(gv)
      switch(ix) {
        case 0: RETVAL = gv->file; break;
        case 1: RETVAL = gv->name; break;
      }
  }
OUTPUT:
  RETVAL

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV::SCALAR

void
_set_scalar_fields(self, flags, uv, nv, pv, pvlen, ourstash_at)
  HV   *self
  int   flags
  long  uv
  SV   *nv
  SV   *pv
  long  pvlen
  long  ourstash_at
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);

    sv->flags       = flags;
    sv->uv          = uv;
    sv->pvlen       = pvlen;
    sv->ourstash_at = ourstash_at;

    if(flags & 0x04)
      if(SvNOK(nv))
        sv->nv = SvNV(nv);
      else
        sv->flags &= ~0x04;

    if(flags & 0x08) {
      sv->pv_strlen = SvCUR(pv);

      if(SvLEN(pv) && !SvOOK(pv)) {
        /* Swipe pv's buffer */
        sv->pv = SvPVX(pv);

        SvPVX(pv) = NULL;
        SvCUR(pv) = 0;
        SvLEN(pv) = 0;
        SvPOK_off(pv);
      }
      else {
        sv->pv = savepvn(SvPV_nolen(pv), SvCUR(pv));
      }
    }
  }

void DESTROY(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);

    // TODO: don't crash
    //if(sv->pv)
    //  Safefree(sv->pv);

    free_pmat_sv((struct pmat_sv *)sv);
  }

SV *uv(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);
    RETVAL = newSV(0);
    if(sv && sv->flags & 0x01 && !(sv->flags & 0x02))
      sv_setuv(RETVAL, sv->uv);
  }
OUTPUT:
  RETVAL

SV *iv(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);
    RETVAL = newSV(0);
    if(sv && sv->flags & 0x01 && sv->flags & 0x02)
      sv_setiv(RETVAL, sv->uv);
  }
OUTPUT:
  RETVAL

SV *nv(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);
    RETVAL = newSV(0);
    if(sv && sv->flags & 0x04)
      sv_setnv(RETVAL, sv->nv);
  }
OUTPUT:
  RETVAL

SV *pv(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);
    RETVAL = newSV(0);
    if(sv && sv->flags & 0x08)
      sv_setpvn(RETVAL, sv->pv, sv->pv_strlen);
  }
OUTPUT:
  RETVAL

SV *pvlen(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);
    RETVAL = newSV(0);
    if(sv && sv->flags & 0x08)
      sv_setuv(RETVAL, sv->pvlen);
  }
OUTPUT:
  RETVAL

long
ourstash_at(self)
  HV   *self
CODE:
  {
    struct pmat_sv_scalar *sv = (struct pmat_sv_scalar *)get_pmat_sv(self);
    RETVAL = sv ? sv->ourstash_at : 0;
  }
OUTPUT:
  RETVAL

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV::REF

void
_set_ref_fields(self, rv_at, ourstash_at, is_weak)
  HV   *self
  long  rv_at
  long  ourstash_at
  char  is_weak
CODE:
  {
    struct pmat_sv_ref *rv = (struct pmat_sv_ref *)get_pmat_sv(self);

    rv->rv_at       = rv_at;
    rv->ourstash_at = ourstash_at;
    rv->is_weak     = is_weak;
  }

long
rv_at(self)
  HV   *self
ALIAS:
  rv_at       = 0
  ourstash_at = 1
CODE:
  {
    struct pmat_sv_ref *rv = (struct pmat_sv_ref *)get_pmat_sv(self);
    if(rv)
      switch(ix) {
        case 0: RETVAL = rv->rv_at;       break;
        case 1: RETVAL = rv->ourstash_at; break;
      }
  }
OUTPUT:
  RETVAL

char
is_weak(self)
  HV   *self
CODE:
  {
    struct pmat_sv_ref *rv = (struct pmat_sv_ref *)get_pmat_sv(self);
    RETVAL = rv ? rv->is_weak : 0;
  }
OUTPUT:
  RETVAL

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV::ARRAY

void
_set_array_fields(self, flags, elems_at)
  HV  *self
  int  flags
  AV  *elems_at
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);
    long n, i;

    av->flags    = flags;
    av->padcv_at = 0;

    n = AvMAX(elems_at) + 1;
    av->n_elems = n;

    Newx(av->elems_at, n, long);
    for(i = 0; i < n; i++)
      av->elems_at[i] = SvUV(AvARRAY(elems_at)[i]);
  }

void DESTROY(self)
  HV   *self
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);

    Safefree(av->elems_at);

    free_pmat_sv((struct pmat_sv *)av);
  }

void
_clear_elem(self, i)
  HV            *self
  unsigned long  i
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);
    if(av && i < av->n_elems)
      av->elems_at[i] = 0;
  }

void
_set_padcv_at(self, padcv_at)
  HV   *self
  long  padcv_at
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);
    av->padcv_at = padcv_at;
  }

int
is_unreal(self)
  HV   *self
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);
    RETVAL = av ? av->flags & 0x01 : 0;
  }
OUTPUT:
  RETVAL

long
n_elems(self)
  HV   *self
ALIAS:
  n_elems  = 0
  padcv_at = 1
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);
    if(av)
      switch(ix) {
        case 0: RETVAL = av->n_elems;  break;
        case 1: RETVAL = av->padcv_at; break;
      }
  }
OUTPUT:
  RETVAL

long
elem_at(self, i)
  HV            *self
  unsigned long  i
CODE:
  {
    struct pmat_sv_array *av = (struct pmat_sv_array *)get_pmat_sv(self);
    if(av && i < av->n_elems)
      RETVAL = av->elems_at[i];
  }
OUTPUT:
  RETVAL

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV::HASH

void
_set_hash_fields(self, backrefs_at, values_at)
  HV   *self
  long  backrefs_at
  HV   *values_at
CODE:
  {
    long i, n;
    HE *ent;
    struct pmat_sv_hash *hv = (struct pmat_sv_hash *)get_pmat_sv(self);

    n = hv_iterinit(values_at);

    hv->backrefs_at = backrefs_at;
    hv->n_values    = n;

    Newx(hv->values_at, n, struct pmat_hval);
    for(i = 0; ent = hv_iternext(values_at); i++) {
      I32 klen;
      const char *key = hv_iterkey(ent, &klen);

      hv->values_at[i].key   = save_string(key, klen);
      hv->values_at[i].klen  = klen;
      hv->values_at[i].value = SvUV(hv_iterval(values_at, ent));
    }

    // TODO: sort the values so we can binsearch for them later
  }

void DESTROY(self)
  HV   *self
CODE:
  {
    struct pmat_sv_hash *hv = (struct pmat_sv_hash *)get_pmat_sv(self);
    long i;

    for(i = 0; i < hv->n_values; i++)
      drop_string(hv->values_at[i].key, hv->values_at[i].klen);

    Safefree(hv->values_at);

    free_pmat_sv((struct pmat_sv *)hv);
  }

long
backrefs_at(self)
  HV   *self
ALIAS:
  backrefs_at = 0
  n_values    = 1
CODE:
  {
    struct pmat_sv_hash *hv = (struct pmat_sv_hash *)get_pmat_sv(self);
    if(hv)
      switch(ix) {
        case 0: RETVAL = hv->backrefs_at; break;
        case 1: RETVAL = hv->n_values;    break;
      }
  }
OUTPUT:
  RETVAL

void
keys(self)
  HV    *self
ALIAS:
  keys      = 0
  values_at = 1
PPCODE:
  {
    struct pmat_sv_hash *hv = (struct pmat_sv_hash *)get_pmat_sv(self);
    long i;

    EXTEND(SP, hv->n_values);
    for(i = 0; i < hv->n_values; i++)
      switch(ix) {
        case 0: // keys
          mPUSHp(hv->values_at[i].key, hv->values_at[i].klen);
          break;
        case 1: // values_at
          mPUSHu(hv->values_at[i].value);
          break;
      }

    XSRETURN(hv->n_values);
  }

SV *
value_at(self, key)
  HV    *self
  SV    *key
CODE:
  {
    struct pmat_sv_hash *hv = (struct pmat_sv_hash *)get_pmat_sv(self);
    long i;
    long klen = SvCUR(key);

    RETVAL = &PL_sv_undef;

    // TODO: store values sorted so we can binsearch
    for(i = 0; i < hv->n_values; i++) {
      if(hv->values_at[i].klen != klen)
        continue;
      if(memcmp(hv->values_at[i].key, SvPV_nolen(key), klen) != 0)
        continue;

      RETVAL = newSVuv(hv->values_at[i].value);
      break;
    }
  }
OUTPUT:
  RETVAL

MODULE = Devel::MAT                PACKAGE = Devel::MAT::SV::CODE

void
_set_code_fields(self, line, flags, oproot, stash_at, outside_at, padlist_at, constval_at, file)
  HV   *self
  long  line
  long  flags
  long  oproot
  long  stash_at
  long  outside_at
  long  padlist_at
  long  constval_at
  SV   *file
CODE:
  {
    struct pmat_sv_code *cv = (struct pmat_sv_code *)get_pmat_sv(self);

    cv->line        = line;
    cv->flags       = flags;
    cv->oproot      = oproot;
    cv->stash_at    = stash_at;
    cv->outside_at  = outside_at;
    cv->padlist_at  = padlist_at;
    cv->constval_at = constval_at;
    cv->protosub_at = 0;
    cv->padnames_at = 0;

    if(SvPOK(file))
      cv->file = save_string(SvPV_nolen(file), 0);
    else
      cv->file = NULL;
  }

void DESTROY(self)
  HV   *self
CODE:
  {
    struct pmat_sv_code *cv = (struct pmat_sv_code *)get_pmat_sv(self);

    if(cv->file)
      drop_string(cv->file, 0);

    free_pmat_sv((struct pmat_sv *)cv);
  }

void
_set_protosub_at(self, addr)
  HV   *self
  long  addr
ALIAS:
  _set_protosub_at = 0
  _set_padnames_at = 1
CODE:
  {
    struct pmat_sv_code *cv = (struct pmat_sv_code *)get_pmat_sv(self);
    switch(ix) {
      case 0: cv->protosub_at = addr; break;
      case 1: cv->padnames_at = addr; break;
    }
  }

int
is_clone(self)
  HV   *self
ALIAS:
  is_clone       = 0x01
  is_cloned      = 0x02
  is_xsub        = 0x04
  is_weakoutside = 0x08
  is_cvgv_rc     = 0x10
CODE:
  {
    struct pmat_sv_code *cv = (struct pmat_sv_code *)get_pmat_sv(self);
    RETVAL = cv ? cv->flags & ix : 0;
  }
OUTPUT:
  RETVAL

long
line(self)
  HV   *self
ALIAS:
  line        = 0
  oproot      = 1
  stash_at    = 2
  outside_at  = 3
  padlist_at  = 4
  constval_at = 5
  protosub_at = 6
  padnames_at = 7
CODE:
  {
    struct pmat_sv_code *cv = (struct pmat_sv_code *)get_pmat_sv(self);
    if(cv)
      switch(ix) {
        case 0: RETVAL = cv->line;        break;
        case 1: RETVAL = cv->oproot;      break;
        case 2: RETVAL = cv->stash_at;    break;
        case 3: RETVAL = cv->outside_at;  break;
        case 4: RETVAL = cv->padlist_at;  break;
        case 5: RETVAL = cv->constval_at; break;
        case 6: RETVAL = cv->protosub_at; break;
        case 7: RETVAL = cv->padnames_at; break;
      }
  }
OUTPUT:
  RETVAL

const char *
file(self)
  HV   *self
ALIAS:
  file = 0
CODE:
  {
    struct pmat_sv_code *cv = (struct pmat_sv_code *)get_pmat_sv(self);
    if(cv)
      switch(ix) {
        case 0: RETVAL = cv->file; break;
      }
  }
OUTPUT:
  RETVAL
