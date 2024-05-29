/*
 * Copyright (c) 2009-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of the Redis Source Available License 2.0
 * (RSALv2) or the Server Side Public License v1 (SSPLv1).
 */

#include "server.h"
#include "ebuckets.h"
#include <math.h>

/* Threshold for HEXPIRE and HPERSIST to be considered whether it is worth to
 * update the expiration time of the hash object in global HFE DS. */
#define HASH_NEW_EXPIRE_DIFF_THRESHOLD max(4000, 1<<EB_BUCKET_KEY_PRECISION)

/* Returned by hashTypeGetValue() */
typedef enum GetFieldRes {
    /* common (Used by hashTypeGet* value family) */
    GETF_OK = 0,
    GETF_NOT_FOUND,         /* The field was not found. */

    /* used only by hashTypeGetValue() */
    GETF_EXPIRED,           /* Logically expired but not yet deleted. */
    GETF_EXPIRED_HASH,      /* Delete hash since retrieved field was expired and
                             * it was the last field in the hash. */
} GetFieldRes;

/* hash field expiration (HFE) funcs */
static ExpireAction onFieldExpire(eItem item, void *ctx);
static ExpireMeta* hfieldGetExpireMeta(const eItem field);
static ExpireMeta *hashGetExpireMeta(const eItem hash);
static void hexpireGenericCommand(client *c, const char *cmd, long long basetime, int unit);
static ExpireAction hashTypeActiveExpire(eItem hashObj, void *ctx);
static void hfieldPersist(robj *hashObj, hfield field);
static void propagateHashFieldDeletion(redisDb *db, sds key, char *field, size_t fieldLen);

/* hash dictType funcs */
static int dictHfieldKeyCompare(dict *d, const void *key1, const void *key2);
static uint64_t dictMstrHash(const void *key);
static void dictHfieldDestructor(dict *d, void *field);
static size_t hashDictWithExpireMetadataBytes(dict *d);
static void hashDictWithExpireOnRelease(dict *d);
static robj* hashTypeLookupWriteOrCreate(client *c, robj *key);

/*-----------------------------------------------------------------------------
 * Define dictType of hash
 *
 * - Stores fields as mstr strings with optional metadata to attach TTL
 * - Note that small hashes are represented with listpacks
 * - Once expiration is set for a field, the dict instance and corresponding
 *   dictType are replaced with a dict containing metadata for Hash Field
 *   Expiration (HFE) and using dictType `mstrHashDictTypeWithHFE`
 *----------------------------------------------------------------------------*/
dictType mstrHashDictType = {
    dictSdsHash,                                /* lookup hash function */
    NULL,                                       /* key dup */
    NULL,                                       /* val dup */
    dictSdsMstrKeyCompare,                      /* lookup key compare */
    dictHfieldDestructor,                       /* key destructor */
    dictSdsDestructor,                          /* val destructor */
    .storedHashFunction = dictMstrHash,         /* stored hash function */
    .storedKeyCompare = dictHfieldKeyCompare,   /* stored key compare */
};

/* Define alternative dictType of hash with hash-field expiration (HFE) support */
dictType mstrHashDictTypeWithHFE = {
    dictSdsHash,                                /* lookup hash function */
    NULL,                                       /* key dup */
    NULL,                                       /* val dup */
    dictSdsMstrKeyCompare,                      /* lookup key compare */
    dictHfieldDestructor,                       /* key destructor */
    dictSdsDestructor,                          /* val destructor */
    .storedHashFunction = dictMstrHash,         /* stored hash function */
    .storedKeyCompare = dictHfieldKeyCompare,   /* stored key compare */
    .dictMetadataBytes = hashDictWithExpireMetadataBytes,
    .onDictRelease = hashDictWithExpireOnRelease,
};

/*-----------------------------------------------------------------------------
 * Hash Field Expiration (HFE) Feature
 *
 * Each hash instance maintains its own set of hash field expiration within its
 * private ebuckets DS. In order to support HFE active expire cycle across hash
 * instances, hashes with associated HFE will be also registered in a global
 * ebuckets DS with expiration time value that reflects their next minimum
 * time to expire. The global HFE Active expiration will be triggered from
 * activeExpireCycle() function and will invoke "local" HFE Active expiration
 * for each hash instance that has expired fields.
 *
 * hashExpireBucketsType - ebuckets-type to be used at the global space
 * (db->hexpires) to register hashes that have one or more fields with time-Expiration.
 * The hashes will be registered in with the expiration time of the earliest field
 * in the hash.
 *----------------------------------------------------------------------------*/
EbucketsType hashExpireBucketsType = {
    .onDeleteItem = NULL,
    .getExpireMeta = hashGetExpireMeta,   /* get ExpireMeta attached to each hash */
    .itemsAddrAreOdd = 0,                 /* Addresses of dict are even */
};

/* dictExpireMetadata - ebuckets-type for hash fields with time-Expiration. ebuckets
 * instance Will be attached to each hash that has at least one field with expiry
 * time. */
EbucketsType hashFieldExpireBucketsType = {
    .onDeleteItem = NULL,
    .getExpireMeta = hfieldGetExpireMeta, /* get ExpireMeta attached to each field */
    .itemsAddrAreOdd = 1,                 /* Addresses of hfield (mstr) are odd!! */
};

/* ActiveExpireCtx passed to hashTypeActiveExpire() */
typedef struct ActiveExpireCtx {
    uint32_t fieldsToExpireQuota;
    redisDb *db;
} ActiveExpireCtx;

/* OnFieldExpireCtx passed to OnFieldExpire() */
typedef struct OnFieldExpireCtx {
    robj *hashObj;
    redisDb *db;
} OnFieldExpireCtx;

/* The implementation of hashes by dict was modified from storing fields as sds
 * strings to store "mstr" (Immutable string with metadata) in order to be able to
 * attach TTL (ExpireMeta) to the hash-field. This usage of mstr opens up the
 * opportunity for future features to attach additional metadata by need to the
 * fields.
 *
 * The following defines new hfield kind of mstr */
typedef enum HfieldMetaFlags {
    HFIELD_META_EXPIRE = 0,
} HfieldMetaFlags;

mstrKind mstrFieldKind = {
    .name = "hField",

    /* Taking care that all metaSize[*] values are even ensures that all
     * addresses of hfield instances will be odd. */
    .metaSize[HFIELD_META_EXPIRE] = sizeof(ExpireMeta),
};
static_assert(sizeof(struct ExpireMeta ) % 2 == 0, "must be even!");

/* Used by hpersistCommand() */
typedef enum SetPersistRes {
    HFE_PERSIST_NO_FIELD =     -2,   /* No such hash-field */
    HFE_PERSIST_NO_TTL =       -1,   /* No TTL attached to the field */
    HFE_PERSIST_OK =            1
} SetPersistRes;

static inline int isDictWithMetaHFE(dict *d) {
    return d->type == &mstrHashDictTypeWithHFE;
}

/*-----------------------------------------------------------------------------
 * setex* - Set field OR field's expiration
 *
 * Whereas setting plain fields is rather straightforward, setting expiration
 * time to fields might be time-consuming and complex since each update of
 * expiration time, not only updates `ebuckets` of corresponding hash, but also
 * might update `ebuckets` of global HFE DS. It is required to opt sequence of
 * field updates with expirartion for a given hash, such that only once done,
 * the global HFE DS will get updated.
 *
 * To do so, follow the scheme:
 * 1. Call hashTypeSetExInit() to initialize the HashTypeSetEx struct.
 * 2. Call hashTypeSetEx() one time or more, for each field/expiration update.
 * 3. Call hashTypeSetExDone() for notification and update of global HFE.
 *
 * If expiration is not required, then avoid this API and use instead hashTypeSet()
 *----------------------------------------------------------------------------*/

/* Returned value of hashTypeSetEx() */
typedef enum SetExRes {
    /* Common res from hashTypeSetEx() */
    HSETEX_OK =                1,   /* Expiration time set/updated as expected */

    /* If provided HashTypeSetEx struct to hashTypeSetEx() */
    HSETEX_NO_FIELD =         -2,   /* No such hash-field */
    HSETEX_NO_CONDITION_MET =  0,   /* Specified NX | XX | GT | LT condition not met */
    HSETEX_DELETED =           2,   /* Field deleted because the specified time is in the past */

    /* If not provided HashTypeSetEx struct to hashTypeSetEx() (plain HSET) */
    HSET_UPDATE =              4,   /* Update of the field without expiration time */

} SetExRes;

/* Used by httlGenericCommand() */
typedef enum GetExpireTimeRes {
    HFE_GET_NO_FIELD =          -2, /* No such hash-field */
    HFE_GET_NO_TTL =            -1, /* No TTL attached to the field */
} GetExpireTimeRes;

/* on fail return HSETEX_NO_CONDITION_MET */
typedef enum FieldSetCond {
    FIELD_CREATE_OR_OVRWRT = 0,
    FIELD_DONT_CREATE      = 1,
    FIELD_DONT_CREATE2     = 2,     /* on fail return HSETEX_NO_FIELD */
    FIELD_DONT_OVRWRT      = 3
} FieldSetCond;

typedef enum FieldGet { /* TBD */
    FIELD_GET_NONE = 0,
    FIELD_GET_NEW  = 1,
    FIELD_GET_OLD  = 2
} FieldGet;

typedef enum ExpireSetCond {
    HFE_NX = 1<<0,
    HFE_XX = 1<<1,
    HFE_GT = 1<<2,
    HFE_LT = 1<<3
} ExpireSetCond;

typedef struct HashTypeSet {
    sds value;
    int flags;
} HashTypeSet;

/* Used by hashTypeSetEx() for setting fields or their expiry  */
typedef struct HashTypeSetEx {

    /*** config ***/
    FieldSetCond fieldSetCond;          /* [DCF | DOF] */
    ExpireSetCond expireSetCond;        /* [XX | NX | GT | LT] */

    /*** metadata ***/
    uint64_t minExpire;                 /* if uninit EB_EXPIRE_TIME_INVALID */
    redisDb *db;
    robj *key, *hashObj;
    uint64_t minExpireFields;           /* Trace updated fields and their previous/new
                                         * minimum expiration time. If minimum recorded
                                         * is above minExpire of the hash, then we don't
                                         * have to update global HFE DS */
    int fieldDeleted;                   /* Number of fields deleted */
    int fieldUpdated;                   /* Number of fields updated */

    /* Optionally provide client for notification */
    client *c;
    const char *cmd;
} HashTypeSetEx;

static SetExRes hashTypeSetExListpack(redisDb *db, robj *o, sds field, HashTypeSet *setParams,
                                      uint64_t expireAt, HashTypeSetEx *exParams);

int hashTypeSetExInit(robj *key, robj *o, client *c, redisDb *db, const char *cmd,
                      FieldSetCond fieldSetCond, ExpireSetCond expireSetCond, HashTypeSetEx *ex);

SetExRes hashTypeSetEx(redisDb *db, robj *o, sds field, HashTypeSet *setKeyVal,
                       uint64_t expireAt, HashTypeSetEx *exInfo);

void hashTypeSetExDone(HashTypeSetEx *e);

/*-----------------------------------------------------------------------------
 * Accessor functions for dictType of hash
 *----------------------------------------------------------------------------*/

static int dictHfieldKeyCompare(dict *d, const void *key1, const void *key2)
{
    int l1,l2;
    UNUSED(d);

    l1 = hfieldlen((hfield)key1);
    l2 = hfieldlen((hfield)key2);
    if (l1 != l2) return 0;
    return memcmp(key1, key2, l1) == 0;
}

static uint64_t dictMstrHash(const void *key) {
    return dictGenHashFunction((unsigned char*)key, mstrlen((char*)key));
}

static void dictHfieldDestructor(dict *d, void *field) {

    /* If attached TTL to the field, then remove it from hash's private ebuckets. */
    if (hfieldGetExpireTime(field) != EB_EXPIRE_TIME_INVALID) {
        dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *) dictMetadata(d);
        ebRemove(&dictExpireMeta->hfe, &hashFieldExpireBucketsType, field);
    }

    hfieldFree(field);

    /* Don't have to update global HFE DS. It's unnecessary. Implementing this
     * would introduce significant complexity and overhead for an operation that
     * isn't critical. In the worst case scenario, the hash will be efficiently
     * updated later by an active-expire operation, or it will be removed by the
     * hash's dbGenericDelete() function. */
}

static size_t hashDictWithExpireMetadataBytes(dict *d) {
    UNUSED(d);
    /* expireMeta of the hash, ref to ebuckets and pointer to hash's key */
    return sizeof(dictExpireMetadata);
}

static void hashDictWithExpireOnRelease(dict *d) {
    /* for sure allocated with metadata. Otherwise, this func won't be registered */
    dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *) dictMetadata(d);
    ebDestroy(&dictExpireMeta->hfe, &hashFieldExpireBucketsType, NULL);
}

/*-----------------------------------------------------------------------------
 * listpackEx functions
 *----------------------------------------------------------------------------*/
/*
 * If any of hash field expiration command is called on a listpack hash object
 * for the first time, we convert it to OBJ_ENCODING_LISTPACK_EX encoding.
 * We allocate "struct listpackEx" which holds listpack pointer and metadata to
 * register key to the global DS. In the listpack, we append another TTL entry
 * for each field-value pair. From now on, listpack will have triplets in it:
 * field-value-ttl. If TTL is not set for a field, we store 'zero' as the TTL
 * value. 'zero' is encoded as two bytes in the listpack. Memory overhead of a
 * non-existing TTL will be two bytes per field.
 *
 * Fields in the listpack will be ordered by TTL. Field with the smallest expiry
 * time will be the first item. Fields without TTL will be at the end of the
 * listpack. This way, it is easier/faster to find expired items.
 */

#define HASH_LP_NO_TTL 0

struct listpackEx *listpackExCreate(void) {
    listpackEx *lpt = zcalloc(sizeof(*lpt));
    lpt->meta.trash = 1;
    lpt->lp = NULL;
    lpt->key = NULL;
    return lpt;
}

static void listpackExFree(listpackEx *lpt) {
    lpFree(lpt->lp);
    zfree(lpt);
}

struct lpFingArgs {
    uint64_t max_to_search; /* [in] Max number of tuples to search */
    uint64_t expire_time;   /* [in] Find the tuple that has a TTL larger than expire_time */
    unsigned char *p;       /* [out] First item of the tuple that has a TTL larger than expire_time */
    int expired;            /* [out] Number of tuples that have TTLs less than expire_time */
    int index;              /* Internally used */
    unsigned char *fptr;    /* Internally used, temp ptr */
};

/* Callback for lpFindCb(). Used to find number of expired fields as part of
 * active expiry or when trying to find the position for the new field according
 * to its expiry time.*/
static int cbFindInListpack(const unsigned char *lp, unsigned char *p,
                            void *user, unsigned char *s, long long slen)
{
    (void) lp;
    struct lpFingArgs *r = user;

    r->index++;

    if (r->max_to_search == 0)
        return 0; /* Break the loop and return */

    if (r->index % 3 == 1) {
        r->fptr = p;  /* First item of the tuple. */
    } else if (r->index % 3 == 0) {
        serverAssert(!s);

        /* Third item of a tuple is expiry time */
        if (slen == HASH_LP_NO_TTL || (uint64_t) slen >= r->expire_time) {
            r->p = r->fptr;
            return 0; /* Break the loop and return */
        }
        r->expired++;
        r->max_to_search--;
    }

    return 1;
}

/* Returns number of expired fields. */
static uint64_t listpackExExpireDryRun(const robj *o) {
    serverAssert(o->encoding == OBJ_ENCODING_LISTPACK_EX);

    listpackEx *lpt = o->ptr;

    struct lpFingArgs r = {
        .max_to_search = UINT64_MAX,
        .expire_time = commandTimeSnapshot(),
    };

    lpFindCb(lpt->lp, NULL, &r, cbFindInListpack, 0);
    return r.expired;
}

/* Returns the expiration time of the item with the nearest expiration. */
static uint64_t listpackExGetMinExpire(robj *o) {
    serverAssert(o->encoding == OBJ_ENCODING_LISTPACK_EX);

    long long expireAt;
    unsigned char *fptr;
    listpackEx *lpt = o->ptr;

    /* As fields are ordered by expire time, first field will have the smallest
     * expiry time. Third element is the expiry time of the first field */
    fptr = lpSeek(lpt->lp, 2);
    if (fptr != NULL) {
        serverAssert(lpGetIntegerValue(fptr, &expireAt));

        /* Check if this is a non-volatile field. */
        if (expireAt != HASH_LP_NO_TTL)
            return expireAt;
    }

    return EB_EXPIRE_TIME_INVALID;
}

/* Walk over fields and delete the expired ones. */
void listpackExExpire(redisDb *db, robj *o, ExpireInfo *info) {
    serverAssert(o->encoding == OBJ_ENCODING_LISTPACK_EX);
    uint64_t expired = 0, min = EB_EXPIRE_TIME_INVALID;
    unsigned char *ptr;
    listpackEx *lpt = o->ptr;

    ptr = lpFirst(lpt->lp);

    while (ptr != NULL && (info->itemsExpired < info->maxToExpire)) {
        long long val;
        int64_t flen;
        unsigned char intbuf[LP_INTBUF_SIZE], *fref;

        fref = lpGet(ptr, &flen, intbuf);

        ptr = lpNext(lpt->lp, ptr);
        serverAssert(ptr);
        ptr = lpNext(lpt->lp, ptr);
        serverAssert(ptr && lpGetIntegerValue(ptr, &val));

        /* Fields are ordered by expiry time. If we reached to a non-expired
         * or a non-volatile field, we know rest is not yet expired. */
        if (val == HASH_LP_NO_TTL || (uint64_t) val > info->now)
            break;

        propagateHashFieldDeletion(db, ((listpackEx *) o->ptr)->key, (char *)((fref) ? fref : intbuf), flen);

        ptr = lpNext(lpt->lp, ptr);

        info->itemsExpired++;
        expired++;
    }

    if (expired)
        lpt->lp = lpDeleteRange(lpt->lp, 0, expired * 3);

    min = hashTypeGetNextTimeToExpire(o);
    info->nextExpireTime = (min != EB_EXPIRE_TIME_INVALID) ? min : 0;
}

static void listpackExAddInternal(robj *o, listpackEntry ent[3]) {
    listpackEx *lpt = o->ptr;

    /* Shortcut, just append at the end if this is a non-volatile field. */
    if (ent[2].lval == HASH_LP_NO_TTL) {
        lpt->lp = lpBatchAppend(lpt->lp, ent, 3);
        return;
    }

    struct lpFingArgs r = {
            .max_to_search = UINT64_MAX,
            .expire_time = ent[2].lval,
    };

    /* Check if there is a field with a larger TTL. */
    lpFindCb(lpt->lp, NULL, &r, cbFindInListpack, 0);

    /* If list is empty or there is no field with a larger TTL, result will be
     * NULL. Otherwise, just insert before the found item.*/
    if (r.p)
        lpt->lp = lpBatchInsert(lpt->lp, r.p, LP_BEFORE, ent, 3, NULL);
    else
        lpt->lp = lpBatchAppend(lpt->lp, ent, 3);
}

/* Add new field ordered by expire time. */
void listpackExAddNew(robj *o, char *field, size_t flen,
                      char *value, size_t vlen, uint64_t expireAt) {
    listpackEntry ent[3] = {
        {.sval = (unsigned char*) field, .slen = flen},
        {.sval = (unsigned char*) value, .slen = vlen},
        {.lval = expireAt}
    };

    listpackExAddInternal(o, ent);
}

/* If expiry time is changed, this function will place field into the correct
 * position. First, it deletes the field and re-inserts to the listpack ordered
 * by expiry time. */
static void listpackExUpdateExpiry(robj *o, sds field,
                                   unsigned char *fptr,
                                   unsigned char *vptr,
                                   uint64_t expire_at) {
    unsigned int slen = 0;
    long long val = 0;
    unsigned char tmp[512] = {0};
    unsigned char *valstr;
    sds tmpval = NULL;
    listpackEx *lpt = o->ptr;

    /* Copy value */
    valstr = lpGetValue(vptr, &slen, &val);
    if (valstr) {
        /* Normally, item length in the listpack is limited by
         * 'hash-max-listpack-value' config. It is unlikely, but it might be
         * larger than sizeof(tmp). */
        if (slen > sizeof(tmp))
            tmpval = sdsnewlen(valstr, slen);
        else
            memcpy(tmp, valstr, slen);
    }

    /* Delete field name, value and expiry time */
    lpt->lp = lpDeleteRangeWithEntry(lpt->lp, &fptr, 3);

    listpackEntry ent[3] = {{0}};

    ent[0].sval = (unsigned char*) field;
    ent[0].slen = sdslen(field);

    if (valstr) {
        ent[1].sval = tmpval ? (unsigned char *) tmpval : tmp;
        ent[1].slen = slen;
    } else {
        ent[1].lval = val;
    }
    ent[2].lval = expire_at;

    listpackExAddInternal(o, ent);
    sdsfree(tmpval);
}

/* Update field expire time. */
SetExRes hashTypeSetExpiryListpack(HashTypeSetEx *ex, sds field,
                                   unsigned char *fptr, unsigned char *vptr,
                                   unsigned char *tptr, uint64_t expireAt)
{
    long long expireTime;
    uint64_t prevExpire = EB_EXPIRE_TIME_INVALID;

    serverAssert(lpGetIntegerValue(tptr, &expireTime));

    if (expireTime != HASH_LP_NO_TTL) {
        prevExpire = (uint64_t) expireTime;
    }

    if (prevExpire == EB_EXPIRE_TIME_INVALID) {
        /* For fields without expiry, LT condition is considered valid */
        if (ex->expireSetCond & (HFE_XX | HFE_GT))
            return HSETEX_NO_CONDITION_MET;
    } else {
        if (((ex->expireSetCond == HFE_GT) && (prevExpire >= expireAt)) ||
            ((ex->expireSetCond == HFE_LT) && (prevExpire <= expireAt)) ||
            (ex->expireSetCond == HFE_NX) )
            return HSETEX_NO_CONDITION_MET;

        /* Track of minimum expiration time (only later update global HFE DS) */
        if (ex->minExpireFields > prevExpire)
            ex->minExpireFields = prevExpire;
    }

    /* if expiration time is in the past */
    if (unlikely(checkAlreadyExpired(expireAt))) {
        hashTypeDelete(ex->hashObj, field, 1);
        ex->fieldDeleted++;
        return HSETEX_DELETED;
    }

    if (ex->minExpireFields > expireAt)
        ex->minExpireFields = expireAt;

    listpackExUpdateExpiry(ex->hashObj, field, fptr, vptr, expireAt);
    ex->fieldUpdated++;
    return HSETEX_OK;
}

/* Returns 1 if expired */
int hashTypeIsExpired(const robj *o, uint64_t expireAt) {
    if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        if (expireAt == HASH_LP_NO_TTL)
            return 0;
    } else if (o->encoding == OBJ_ENCODING_HT) {
        if (expireAt == EB_EXPIRE_TIME_INVALID)
            return 0;
    } else {
        serverPanic("Unknown encoding: %d", o->encoding);
    }

    return (mstime_t) expireAt < commandTimeSnapshot();
}

/* Returns listpack pointer of the object. */
unsigned char *hashTypeListpackGetLp(robj *o) {
    if (o->encoding == OBJ_ENCODING_LISTPACK)
        return o->ptr;
    else if (o->encoding == OBJ_ENCODING_LISTPACK_EX)
        return ((listpackEx*)o->ptr)->lp;

    serverPanic("Unknown encoding: %d", o->encoding);
}

/*-----------------------------------------------------------------------------
 * Hash type API
 *----------------------------------------------------------------------------*/

/* Check the length of a number of objects to see if we need to convert a
 * listpack to a real hash. Note that we only check string encoded objects
 * as their string length can be queried in constant time. */
void hashTypeTryConversion(redisDb *db, robj *o, robj **argv, int start, int end) {
    int i;
    size_t sum = 0;

    if (o->encoding != OBJ_ENCODING_LISTPACK && o->encoding != OBJ_ENCODING_LISTPACK_EX)
        return;

    /* We guess that most of the values in the input are unique, so
     * if there are enough arguments we create a pre-sized hash, which
     * might over allocate memory if there are duplicates. */
    size_t new_fields = (end - start + 1) / 2;
    if (new_fields > server.hash_max_listpack_entries) {
        hashTypeConvert(o, OBJ_ENCODING_HT, &db->hexpires);
        dictExpand(o->ptr, new_fields);
        return;
    }

    for (i = start; i <= end; i++) {
        if (!sdsEncodedObject(argv[i]))
            continue;
        size_t len = sdslen(argv[i]->ptr);
        if (len > server.hash_max_listpack_value) {
            hashTypeConvert(o, OBJ_ENCODING_HT, &db->hexpires);
            return;
        }
        sum += len;
    }
    if (!lpSafeToAdd(hashTypeListpackGetLp(o), sum))
        hashTypeConvert(o, OBJ_ENCODING_HT, &db->hexpires);
}

/* Get the value from a listpack encoded hash, identified by field. */
GetFieldRes hashTypeGetFromListpack(robj *o, sds field,
                            unsigned char **vstr,
                            unsigned int *vlen,
                            long long *vll,
                            uint64_t *expiredAt)
{
    *expiredAt = EB_EXPIRE_TIME_INVALID;
    unsigned char *zl, *fptr = NULL, *vptr = NULL;

    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        zl = o->ptr;
        fptr = lpFirst(zl);
        if (fptr != NULL) {
            fptr = lpFind(zl, fptr, (unsigned char*)field, sdslen(field), 1);
            if (fptr != NULL) {
                /* Grab pointer to the value (fptr points to the field) */
                vptr = lpNext(zl, fptr);
                serverAssert(vptr != NULL);
            }
        }
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        long long expire;
        unsigned char *h;
        listpackEx *lpt = o->ptr;

        fptr = lpFirst(lpt->lp);
        if (fptr != NULL) {
            fptr = lpFind(lpt->lp, fptr, (unsigned char*)field, sdslen(field), 2);
            if (fptr != NULL) {
                vptr = lpNext(lpt->lp, fptr);
                serverAssert(vptr != NULL);

                h = lpNext(lpt->lp, vptr);
                serverAssert(h && lpGetIntegerValue(h, &expire));
                if (expire != HASH_LP_NO_TTL)
                    *expiredAt = expire;
            }
        }
    } else {
        serverPanic("Unknown hash encoding: %d", o->encoding);
    }

    if (vptr != NULL) {
        *vstr = lpGetValue(vptr, vlen, vll);
        return GETF_OK;
    }

    return GETF_NOT_FOUND;
}

/* Get the value from a hash table encoded hash, identified by field.
 * Returns NULL when the field cannot be found, otherwise the SDS value
 * is returned. */
GetFieldRes hashTypeGetFromHashTable(robj *o, sds field, sds *value, uint64_t *expiredAt) {
    dictEntry *de;

    *expiredAt = EB_EXPIRE_TIME_INVALID;

    serverAssert(o->encoding == OBJ_ENCODING_HT);

    de = dictFind(o->ptr, field);

    if (de == NULL)
        return GETF_NOT_FOUND;

    *expiredAt = hfieldGetExpireTime(dictGetKey(de));
    *value = (sds) dictGetVal(de);
    return GETF_OK;
}

/* Higher level function of hashTypeGet*() that returns the hash value
 * associated with the specified field.
 *
 * Returned:
 * - GetFieldRes: OK: Return    Field's valid value
 *                NOT_FOUND:    Field was not found.
 *                EXPIRED:      Field is expired and Lazy deleted
 *                EXPIRED_HASH: Returned only if the field is the last one in the
 *                              hash and the hash is deleted.
 * - vstr, vlen : if string, ref in either *vstr and *vlen if it's
 *                returned in string form,
 * - vll        : or stored in *vll if it's returned as a number.
 *                If *vll is populated *vstr is set to NULL, so the caller can
 *                always check the function return by checking the return value
 *                for GETF_OK and checking if vll (or vstr) is NULL.
 *
 */
GetFieldRes hashTypeGetValue(redisDb *db, robj *o, sds field, unsigned char **vstr,
                             unsigned int *vlen, long long *vll) {
    uint64_t expiredAt;
    sds key;
    GetFieldRes res;
    if (o->encoding == OBJ_ENCODING_LISTPACK ||
        o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        *vstr = NULL;
        res = hashTypeGetFromListpack(o, field, vstr, vlen, vll, &expiredAt);

        if (res == GETF_NOT_FOUND)
            return GETF_NOT_FOUND;

    } else if (o->encoding == OBJ_ENCODING_HT) {
        sds value = NULL;
        res = hashTypeGetFromHashTable(o, field, &value, &expiredAt);

        if (res == GETF_NOT_FOUND)
            return GETF_NOT_FOUND;

        *vstr = (unsigned char*) value;
        *vlen = sdslen(value);
    } else {
        serverPanic("Unknown hash encoding");
    }

    /* Don't expire anything while loading. It will be done later. */
    if ( (server.loading) ||
         (server.lazy_expire_disabled) ||
         ((server.masterhost) && (server.current_client && (server.current_client->flags & CLIENT_MASTER))) ||
         (expiredAt >= (uint64_t) commandTimeSnapshot()) )
        return GETF_OK;

    /* Got expired. Extract attached key from LISTPACK_EX/HT */
    if (o->encoding == OBJ_ENCODING_LISTPACK_EX)
        key = ((listpackEx *) o->ptr)->key;
    else
        key = ((dictExpireMetadata *) dictMetadata((dict*)o->ptr))->key;

    /* delete the field and propagate the deletion */
    serverAssert(hashTypeDelete(o, field, 1) == 1);
    propagateHashFieldDeletion(db, key, field, sdslen(field));

    /* If the field is the last one in the hash, then the hash will be deleted */
    if (hashTypeLength(o, 0) == 0) {
        robj *keyObj = createStringObject(key, sdslen(key));
        notifyKeyspaceEvent(NOTIFY_GENERIC, "del", keyObj, db->id);
        dbDelete(db,keyObj);
        decrRefCount(keyObj);
        return GETF_EXPIRED_HASH;
    }

    return GETF_EXPIRED;
}

/* Like hashTypeGetValue() but returns a Redis object, which is useful for
 * interaction with the hash type outside t_hash.c.
 * The function returns NULL if the field is not found in the hash. Otherwise
 * a newly allocated string object with the value is returned.
 *
 * isHashDeleted - If attempted to access expired field and it's the last field
 *                 in the hash, then the hash will as well be deleted. In this case,
 *                 isHashDeleted will be set to 1.
 */
robj *hashTypeGetValueObject(redisDb *db, robj *o, sds field, int *isHashDeleted) {
    unsigned char *vstr;
    unsigned int vlen;
    long long vll;

    *isHashDeleted = 0; /*default*/
    GetFieldRes res = hashTypeGetValue(db,o,field,&vstr,&vlen,&vll);

    if (res == GETF_OK) {
        if (vstr) return createStringObject((char*)vstr,vlen);
        else return createStringObjectFromLongLong(vll);
    }

    if (res == GETF_EXPIRED_HASH)
        *isHashDeleted = 1;

    /* GETF_EXPIRED_HASH, GETF_EXPIRED, GETF_NOT_FOUND */
    return NULL;
}

/* Test if the specified field exists in the given hash. If the field is
 * expired (HFE), then it will be lazy deleted
 *
 * Returns 1 if the field exists, and 0 when it doesn't.
 *
 * isHashDeleted - If attempted to access expired field and it is the last field
 *                 in the hash, then the hash will as well be deleted. In this case,
 *                 isHashDeleted will be set to 1.
 */
int hashTypeExists(redisDb *db, robj *o, sds field, int *isHashDeleted) {
    unsigned char *vstr = NULL;
    unsigned int vlen = UINT_MAX;
    long long vll = LLONG_MAX;

    GetFieldRes res = hashTypeGetValue(db, o, field, &vstr, &vlen, &vll);
    *isHashDeleted = (res == GETF_EXPIRED_HASH) ? 1 : 0;
    return (res == GETF_OK) ? 1 : 0;
}

/* Add a new field, overwrite the old with the new value if it already exists.
 * Return 0 on insert and 1 on update.
 *
 * By default, the key and value SDS strings are copied if needed, so the
 * caller retains ownership of the strings passed. However this behavior
 * can be effected by passing appropriate flags (possibly bitwise OR-ed):
 *
 * HASH_SET_TAKE_FIELD  -- The SDS field ownership passes to the function.
 * HASH_SET_TAKE_VALUE  -- The SDS value ownership passes to the function.
 * HASH_SET_KEEP_FIELD --  keep original field along with TTL if already exists
 *
 * When the flags are used the caller does not need to release the passed
 * SDS string(s). It's up to the function to use the string to create a new
 * entry or to free the SDS string before returning to the caller.
 *
 * HASH_SET_COPY corresponds to no flags passed, and means the default
 * semantics of copying the values if needed.
 *
 */
#define HASH_SET_TAKE_FIELD  (1<<0)
#define HASH_SET_TAKE_VALUE  (1<<1)
#define HASH_SET_KEEP_FIELD (1<<2)
#define HASH_SET_COPY 0
int hashTypeSet(redisDb *db, robj *o, sds field, sds value, int flags) {
    HashTypeSet set = {value, flags};
    return (hashTypeSetEx(db, o, field, &set, 0, NULL) == HSET_UPDATE) ? 1 : 0;
}

SetExRes hashTypeSetExpiry(HashTypeSetEx *ex, sds field, uint64_t expireAt, dictEntry **de) {
    dict *ht = ex->hashObj->ptr;
    dictEntry *newEntry = NULL, *existingEntry = NULL;

    /* New field with expiration metadata */
    hfield hfNew = hfieldNew(field, sdslen(field), 1 /*withExpireMeta*/);

    if ((ex->fieldSetCond == FIELD_DONT_CREATE) || (ex->fieldSetCond == FIELD_DONT_CREATE2)) {
        if ((existingEntry = dictFind(ht, field)) == NULL) {
            hfieldFree(hfNew);
            return (ex->fieldSetCond == FIELD_DONT_CREATE) ?
                   HSETEX_NO_CONDITION_MET : HSETEX_NO_FIELD;
        }
    } else {
        dictUseStoredKeyApi(ht, 1);
        newEntry = dictAddRaw(ht, hfNew, &existingEntry);
        dictUseStoredKeyApi(ht, 0);
    }

    if (newEntry) {
        *de = newEntry;

        if (ex->expireSetCond & (HFE_XX | HFE_LT | HFE_GT)) {
            dictDelete(ht, field);
            return HSETEX_NO_CONDITION_MET;
        }
    } else { /* field exist */
        *de = existingEntry;

        if (ex->fieldSetCond == FIELD_DONT_OVRWRT) {
            hfieldFree(hfNew);
            return HSETEX_NO_CONDITION_MET;
        }

        hfield hfOld = dictGetKey(existingEntry);

        /* If field doesn't have expiry metadata attached */
        if (!hfieldIsExpireAttached(hfOld)) {

            /* For fields without expiry, LT condition is considered valid */
            if (ex->expireSetCond & (HFE_XX | HFE_GT)) {
                hfieldFree(hfNew);
                return HSETEX_NO_CONDITION_MET;
            }

            /* Delete old field. Below goanna dictSetKey(..,hfNew) */
            hfieldFree(hfOld);

        } else { /* field has ExpireMeta struct attached */

            /* No need for hfNew (Just modify expire-time of existing field) */
            hfieldFree(hfNew);

            uint64_t prevExpire = hfieldGetExpireTime(hfOld);

            /* If field has valid expiration time, then check GT|LT|NX */
            if (prevExpire != EB_EXPIRE_TIME_INVALID) {
                if (((ex->expireSetCond == HFE_GT) && (prevExpire >= expireAt)) ||
                    ((ex->expireSetCond == HFE_LT) && (prevExpire <= expireAt)) ||
                    (ex->expireSetCond == HFE_NX) )
                    return HSETEX_NO_CONDITION_MET;

                /* remove old expiry time from hash's private ebuckets */
                dictExpireMetadata *dm = (dictExpireMetadata *) dictMetadata(ht);
                ebRemove(&dm->hfe, &hashFieldExpireBucketsType, hfOld);

                /* Track of minimum expiration time (only later update global HFE DS) */
                if (ex->minExpireFields > prevExpire)
                    ex->minExpireFields = prevExpire;

            } else {
                /* field has invalid expiry. No need to ebRemove() */

                /* Check XX|LT|GT */
                if (ex->expireSetCond & (HFE_XX | HFE_GT))
                    return HSETEX_NO_CONDITION_MET;
            }

            /* Reuse hfOld as hfNew and rewrite its expiry with ebAdd() */
            hfNew = hfOld;
        }

        dictSetKey(ht, existingEntry, hfNew);
    }

    /* if expiration time is in the past */
    if (unlikely(checkAlreadyExpired(expireAt))) {
        hashTypeDelete(ex->hashObj, field, 1);
        ex->fieldDeleted++;
        return HSETEX_DELETED;
    }

    if (ex->minExpireFields > expireAt)
        ex->minExpireFields = expireAt;

    dictExpireMetadata *dm = (dictExpireMetadata *) dictMetadata(ht);
    ebAdd(&dm->hfe, &hashFieldExpireBucketsType, hfNew, expireAt);
    ex->fieldUpdated++;
    return HSETEX_OK;
}

/*
 * Set fields OR field's expiration (See also `setex*` comment above)
 *
 * Take care to call first hashTypeSetExInit() and then call this function.
 * Finally, call hashTypeSetExDone() to notify and update global HFE DS.
 *
 * NOTE: this functions is also called during RDB load to set dict-encoded
 *       fields with and without expiration.
 */
SetExRes hashTypeSetEx(redisDb *db, robj *o, sds field, HashTypeSet *setKeyVal,
                       uint64_t expireAt, HashTypeSetEx *exInfo)
{
    SetExRes res = HSETEX_OK;
    int isSetKeyValue  = (setKeyVal) ? 1 : 0;
    int isSetExpire = (exInfo) ? 1 : 0;
    int flags = (setKeyVal) ? setKeyVal->flags : 0;

    /* Check if the field is too long for listpack, and convert before adding the item.
     * This is needed for HINCRBY* case since in other commands this is handled early by
     * hashTypeTryConversion, so this check will be a NOP. */
    if (o->encoding == OBJ_ENCODING_LISTPACK ||
        o->encoding == OBJ_ENCODING_LISTPACK_EX)
    {
        if ( (isSetKeyValue) &&
             (sdslen(field) > server.hash_max_listpack_value ||
              sdslen(setKeyVal->value) > server.hash_max_listpack_value) )
        {
            hashTypeConvert(o, OBJ_ENCODING_HT, &db->hexpires);
        } else {
            res = hashTypeSetExListpack(db, o, field, setKeyVal, expireAt, exInfo);
            goto SetExDone; /*done*/
        }
    }

    if (o->encoding != OBJ_ENCODING_HT)
        serverPanic("Unknown hash encoding");

    /*** now deal with HT ***/
    hfield newField;
    dict *ht = o->ptr;
    dictEntry *de;

    /* If needed to set the field along with expiry */
    if (isSetExpire) {
        res = hashTypeSetExpiry(exInfo, field, expireAt, &de);
        if (res != HSETEX_OK) goto SetExDone;
    } else {
        dictEntry *existing;
        /* Cannot leverage HASH_SET_TAKE_FIELD since hfield is not of type sds */
        newField = hfieldNew(field, sdslen(field), 0);

        /* stored key is different than lookup key */
        dictUseStoredKeyApi(ht, 1);
        de = dictAddRaw(ht, newField, &existing);
        dictUseStoredKeyApi(ht, 0);

        /* If field already exists, then update "field". "Value" will be set afterward */
        if (de == NULL) {
            if (flags & HASH_SET_KEEP_FIELD) {
                /* Not keep old field along with TTL */
                hfieldFree(newField);
            } else {
                /* If attached TTL to the old field, then remove it from hash's private ebuckets */
                hfield oldField = dictGetKey(existing);
                hfieldPersist(o, oldField);
                hfieldFree(oldField);
                dictSetKey(ht, existing, newField);
            }
            sdsfree(dictGetVal(existing));
            res = HSET_UPDATE;
            de = existing;
        }
    }

    /* If need to set value */
    if (isSetKeyValue) {
        if (flags & HASH_SET_TAKE_VALUE) {
            dictSetVal(ht, de, setKeyVal->value);
            flags &= ~HASH_SET_TAKE_VALUE;
        } else {
            dictSetVal(ht, de, sdsdup(setKeyVal->value));
        }
    }

SetExDone:
    /* Free SDS strings we did not referenced elsewhere if the flags
     * want this function to be responsible. */
    if (flags & HASH_SET_TAKE_FIELD && field) sdsfree(field);
    if (flags & HASH_SET_TAKE_VALUE && setKeyVal->value) sdsfree(setKeyVal->value);
    return res;
}

void initDictExpireMetadata(sds key, robj *o) {
    dict *ht = o->ptr;

    dictExpireMetadata *m = (dictExpireMetadata *) dictMetadata(ht);
    m->key = key;
    m->hfe = ebCreate();     /* Allocate HFE DS */
    m->expireMeta.trash = 1; /* mark as trash (as long it wasn't ebAdd()) */
}

/*
 * Init HashTypeSetEx struct before calling hashTypeSetEx()
 *
 * Don't have to provide client and "cmd". If provided, then notification once
 * done by function hashTypeSetExDone().
 */
int hashTypeSetExInit(robj *key, robj *o, client *c, redisDb *db, const char *cmd, FieldSetCond fieldSetCond,
                      ExpireSetCond expireSetCond, HashTypeSetEx *ex)
{
    dict *ht = o->ptr;

    ex->fieldSetCond = fieldSetCond;
    ex->expireSetCond = expireSetCond;
    ex->minExpire = EB_EXPIRE_TIME_INVALID;
    ex->c = c;
    ex->cmd = cmd;
    ex->db = db;
    ex->key = key;
    ex->hashObj = o;
    ex->fieldDeleted = 0;
    ex->fieldUpdated = 0;
    ex->minExpireFields = EB_EXPIRE_TIME_INVALID;

    /* Take care that HASH support expiration */
    if (ex->hashObj->encoding == OBJ_ENCODING_LISTPACK) {
        hashTypeConvert(ex->hashObj, OBJ_ENCODING_LISTPACK_EX, &c->db->hexpires);

        listpackEx *lpt = ex->hashObj->ptr;
        dictEntry *de = dbFind(c->db, key->ptr);
        serverAssert(de != NULL);
        lpt->key = dictGetKey(de);
    } else if (ex->hashObj->encoding == OBJ_ENCODING_HT) {
        /* Take care dict has HFE metadata */
        if (!isDictWithMetaHFE(ht)) {
            /* Realloc (only header of dict) with metadata for hash-field expiration */
            dictTypeAddMeta(&ht, &mstrHashDictTypeWithHFE);
            dictExpireMetadata *m = (dictExpireMetadata *) dictMetadata(ht);
            ex->hashObj->ptr = ht;

            /* Find the key in the keyspace. Need to keep reference to the key for
             * notifications or even removal of the hash */
            dictEntry *de = dbFind(db, key->ptr);
            serverAssert(de != NULL);

            /* Fillup dict HFE metadata */
            m->key = dictGetKey(de); /* reference key in keyspace */
            m->hfe = ebCreate();     /* Allocate HFE DS */
            m->expireMeta.trash = 1; /* mark as trash (as long it wasn't ebAdd()) */
        }
    }

    ex->minExpire = hashTypeGetMinExpire(ex->hashObj);
    return C_OK;
}

/*
 * After calling hashTypeSetEx() for setting fields or their expiry, call this
 * function to notify and update global HFE DS.
 */
void hashTypeSetExDone(HashTypeSetEx *ex) {
    /* Notify keyspace event, update dirty count and update global HFE DS */
    if (ex->fieldDeleted + ex->fieldUpdated > 0) {

        if (ex->c) {
            server.dirty += ex->fieldDeleted + ex->fieldUpdated;
            signalModifiedKey(ex->c, ex->db, ex->key);
            notifyKeyspaceEvent(NOTIFY_HASH, "hexpire", ex->key, ex->db->id);
        }
        if (ex->fieldDeleted && hashTypeLength(ex->hashObj, 0) == 0) {
            dbDelete(ex->db,ex->key);
            if (ex->c) notifyKeyspaceEvent(NOTIFY_GENERIC,"del",ex->key, ex->db->id);
        } else {
            /* If minimum HFE of the hash is smaller than expiration time of the
             * specified fields in the command as well as it is smaller or equal
             * than expiration time provided in the command, then the minimum
             * HFE of the hash won't change following this command. */
            if ((ex->minExpire < ex->minExpireFields))
                return;

            /* retrieve new expired time. It might have changed. */
            uint64_t newMinExpire = hashTypeGetNextTimeToExpire(ex->hashObj);

            /* Calculate the diff between old minExpire and newMinExpire. If it is
             * only few seconds, then don't have to update global HFE DS. At the worst
             * case fields of hash will be active-expired up to few seconds later.
             *
             * In any case, active-expire operation will know to update global
             * HFE DS more efficiently than here for a single item.
             */
            uint64_t diff = (ex->minExpire > newMinExpire) ?
                                (ex->minExpire - newMinExpire) : (newMinExpire - ex->minExpire);
            if (diff < HASH_NEW_EXPIRE_DIFF_THRESHOLD) return;

            if (ex->minExpire != EB_EXPIRE_TIME_INVALID)
                ebRemove(&ex->db->hexpires, &hashExpireBucketsType, ex->hashObj);
            if (newMinExpire != EB_EXPIRE_TIME_INVALID)
                ebAdd(&ex->db->hexpires, &hashExpireBucketsType, ex->hashObj, newMinExpire);
        }
    }
}

/* Check if the field is too long for listpack, and convert before adding the item.
 * This is needed for HINCRBY* case since in other commands this is handled early by
 * hashTypeTryConversion, so this check will be a NOP. */
static SetExRes hashTypeSetExListpack(redisDb *db, robj *o, sds field, HashTypeSet *setParams,
                                      uint64_t expireAt, HashTypeSetEx *exParams)
{
    int res = HSETEX_OK;
    unsigned char *fptr = NULL, *vptr = NULL, *tptr = NULL;

    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        /* If reached here, then no need to set expiration. Otherwise, as precond
         * listpack is converted to listpackex by hashTypeSetExInit() */

        unsigned char *zl = o->ptr;
        fptr = lpFirst(zl);
        if (fptr != NULL) {
            fptr = lpFind(zl, fptr, (unsigned char*)field, sdslen(field), 1);
            if (fptr != NULL) {
                /* Grab pointer to the value (fptr points to the field) */
                vptr = lpNext(zl, fptr);
                serverAssert(vptr != NULL);
                res = HSET_UPDATE;

                /* Replace value */
                zl = lpReplace(zl, &vptr, (unsigned char *) setParams->value, sdslen(setParams->value));
            }
        }

        if (res != HSET_UPDATE) {
            /* Push new field/value pair onto the tail of the listpack */
            zl = lpAppend(zl, (unsigned char*)field, sdslen(field));
            zl = lpAppend(zl, (unsigned char*)setParams->value, sdslen(setParams->value));
        }
        o->ptr = zl;
        goto out;
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = o->ptr;
        long long expireTime = HASH_LP_NO_TTL;

        fptr = lpFirst(lpt->lp);
        if (fptr != NULL) {
            fptr = lpFind(lpt->lp, fptr, (unsigned char*)field, sdslen(field), 2);
            if (fptr != NULL) {
                /* Grab pointer to the value (fptr points to the field) */
                vptr = lpNext(lpt->lp, fptr);
                serverAssert(vptr != NULL);

                if (setParams) {
                    /* Replace value */
                    lpt->lp = lpReplace(lpt->lp, &vptr,
                                        (unsigned char *) setParams->value,
                                        sdslen(setParams->value));

                    fptr = lpPrev(lpt->lp, vptr);
                    serverAssert(fptr != NULL);
                    res = HSET_UPDATE;
                }
                tptr = lpNext(lpt->lp, vptr);
                serverAssert(tptr && lpGetIntegerValue(tptr, &expireTime));

                /* Keep, update or clear TTL */
                if (setParams && setParams->flags & HASH_SET_KEEP_FIELD) {
                    /* keep old field along with TTL */
                } else if (exParams) {
                    res = hashTypeSetExpiryListpack(exParams, field, fptr, vptr, tptr,
                                                    expireAt);
                    if (res != HSETEX_OK)
                        goto out;
                } else if (res == HSET_UPDATE && expireTime != HASH_LP_NO_TTL) {
                    /* Clear TTL */
                    listpackExUpdateExpiry(o, field, fptr, vptr, HASH_LP_NO_TTL);
                }
            }
        }

        if (!fptr) {
            if (setParams) {
                listpackExAddNew(o, field, sdslen(field),
                                 setParams->value, sdslen(setParams->value),
                                 exParams ? expireAt : HASH_LP_NO_TTL);
            } else {
                res = HSETEX_NO_FIELD;
            }
        }
    }
out:
    /* Check if the listpack needs to be converted to a hash table */
    if (hashTypeLength(o, 0) > server.hash_max_listpack_entries)
        hashTypeConvert(o, OBJ_ENCODING_HT, &db->hexpires);

    return res;
}

/* Delete an element from a hash.
 *
 * Return 1 on deleted and 0 on not found.
 * isSdsField - 1 if the field is sds, 0 if it is hfield */
int hashTypeDelete(robj *o, void *field, int isSdsField) {
    int deleted = 0;
    int fieldLen = (isSdsField) ? sdslen((sds)field) : hfieldlen((hfield)field);

    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        unsigned char *zl, *fptr;

        zl = o->ptr;
        fptr = lpFirst(zl);
        if (fptr != NULL) {
            fptr = lpFind(zl, fptr, (unsigned char*)field, fieldLen, 1);
            if (fptr != NULL) {
                /* Delete both of the key and the value. */
                zl = lpDeleteRangeWithEntry(zl,&fptr,2);
                o->ptr = zl;
                deleted = 1;
            }
        }
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        unsigned char *fptr;
        listpackEx *lpt = o->ptr;

        fptr = lpFirst(lpt->lp);
        if (fptr != NULL) {
            fptr = lpFind(lpt->lp, fptr, (unsigned char*)field, fieldLen, 2);
            if (fptr != NULL) {
                /* Delete field, value and ttl */
                lpt->lp = lpDeleteRangeWithEntry(lpt->lp, &fptr, 3);
                deleted = 1;
            }
        }
    } else if (o->encoding == OBJ_ENCODING_HT) {
        /* dictDelete() will call dictHfieldDestructor() */
        dictUseStoredKeyApi((dict*)o->ptr, isSdsField ? 0 : 1);
        if (dictDelete((dict*)o->ptr, field) == C_OK) {
            deleted = 1;
        }
        dictUseStoredKeyApi((dict*)o->ptr, 0);

    } else {
        serverPanic("Unknown hash encoding");
    }
    return deleted;
}

/* Return the number of elements in a hash.
 *
 * Note, subtractExpiredFields=1 might be pricy in case there are many HFEs
 */
unsigned long hashTypeLength(const robj *o, int subtractExpiredFields) {
    unsigned long length = ULONG_MAX;

    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        length = lpLength(o->ptr) / 2;
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = o->ptr;
        length = lpLength(lpt->lp) / 3;

        if (subtractExpiredFields && lpt->meta.trash == 0)
            length -= listpackExExpireDryRun(o);
    } else if (o->encoding == OBJ_ENCODING_HT) {
        uint64_t expiredItems = 0;
        dict *d = (dict*)o->ptr;
        if (subtractExpiredFields && isDictWithMetaHFE(d)) {
            dictExpireMetadata *meta = (dictExpireMetadata *) dictMetadata(d);
            /* If dict registered in global HFE DS */
            if (meta->expireMeta.trash == 0)
                expiredItems = ebExpireDryRun(meta->hfe,
                                              &hashFieldExpireBucketsType,
                                              commandTimeSnapshot());
        }
        length = dictSize(d) - expiredItems;
    } else {
        serverPanic("Unknown hash encoding");
    }
    return length;
}

hashTypeIterator *hashTypeInitIterator(robj *subject) {
    hashTypeIterator *hi = zmalloc(sizeof(hashTypeIterator));
    hi->subject = subject;
    hi->encoding = subject->encoding;

    if (hi->encoding == OBJ_ENCODING_LISTPACK ||
        hi->encoding == OBJ_ENCODING_LISTPACK_EX)
    {
        hi->fptr = NULL;
        hi->vptr = NULL;
        hi->tptr = NULL;
        hi->expire_time = EB_EXPIRE_TIME_INVALID;
    } else if (hi->encoding == OBJ_ENCODING_HT) {
        hi->di = dictGetIterator(subject->ptr);
    } else {
        serverPanic("Unknown hash encoding");
    }
    return hi;
}

void hashTypeReleaseIterator(hashTypeIterator *hi) {
    if (hi->encoding == OBJ_ENCODING_HT)
        dictReleaseIterator(hi->di);
    zfree(hi);
}

/* Move to the next entry in the hash. Return C_OK when the next entry
 * could be found and C_ERR when the iterator reaches the end. */
int hashTypeNext(hashTypeIterator *hi, int skipExpiredFields) {
    hi->expire_time = EB_EXPIRE_TIME_INVALID;
    if (hi->encoding == OBJ_ENCODING_LISTPACK) {
        unsigned char *zl;
        unsigned char *fptr, *vptr;

        zl = hi->subject->ptr;
        fptr = hi->fptr;
        vptr = hi->vptr;

        if (fptr == NULL) {
            /* Initialize cursor */
            serverAssert(vptr == NULL);
            fptr = lpFirst(zl);
        } else {
            /* Advance cursor */
            serverAssert(vptr != NULL);
            fptr = lpNext(zl, vptr);
        }
        if (fptr == NULL) return C_ERR;

        /* Grab pointer to the value (fptr points to the field) */
        vptr = lpNext(zl, fptr);
        serverAssert(vptr != NULL);

        /* fptr, vptr now point to the first or next pair */
        hi->fptr = fptr;
        hi->vptr = vptr;
    } else if (hi->encoding == OBJ_ENCODING_LISTPACK_EX) {
        long long expire_time;
        unsigned char *zl = hashTypeListpackGetLp(hi->subject);
        unsigned char *fptr, *vptr, *tptr;

        fptr = hi->fptr;
        vptr = hi->vptr;
        tptr = hi->tptr;

        if (fptr == NULL) {
            /* Initialize cursor */
            serverAssert(vptr == NULL);
            fptr = lpFirst(zl);
        } else {
            /* Advance cursor */
            serverAssert(tptr != NULL);
            fptr = lpNext(zl, tptr);
        }
        if (fptr == NULL) return C_ERR;

        while (fptr != NULL) {
            /* Grab pointer to the value (fptr points to the field) */
            vptr = lpNext(zl, fptr);
            serverAssert(vptr != NULL);

            tptr = lpNext(zl, vptr);
            serverAssert(tptr && lpGetIntegerValue(tptr, &expire_time));

            if (!skipExpiredFields || !hashTypeIsExpired(hi->subject, expire_time))
                break;

            fptr = lpNext(zl, tptr);
        }
        if (fptr == NULL) return C_ERR;

        /* fptr, vptr now point to the first or next pair */
        hi->fptr = fptr;
        hi->vptr = vptr;
        hi->tptr = tptr;
        hi->expire_time = (expire_time != HASH_LP_NO_TTL) ? (uint64_t) expire_time : EB_EXPIRE_TIME_INVALID;
    } else if (hi->encoding == OBJ_ENCODING_HT) {

        while ((hi->de = dictNext(hi->di)) != NULL) {
            hi->expire_time = hfieldGetExpireTime(dictGetKey(hi->de));
            /* this condition still valid if expire_time equals EB_EXPIRE_TIME_INVALID */
            if (skipExpiredFields && ((mstime_t)hi->expire_time < commandTimeSnapshot()))
                continue;
            return C_OK;
        }
        return C_ERR;
    } else {
        serverPanic("Unknown hash encoding");
    }
    return C_OK;
}

/* Get the field or value at iterator cursor, for an iterator on a hash value
 * encoded as a listpack. Prototype is similar to `hashTypeGetFromListpack`. */
void hashTypeCurrentFromListpack(hashTypeIterator *hi, int what,
                                 unsigned char **vstr,
                                 unsigned int *vlen,
                                 long long *vll,
                                 uint64_t *expireTime)
{
    serverAssert(hi->encoding == OBJ_ENCODING_LISTPACK ||
                 hi->encoding == OBJ_ENCODING_LISTPACK_EX);

    if (what & OBJ_HASH_KEY) {
        *vstr = lpGetValue(hi->fptr, vlen, vll);
    } else {
        *vstr = lpGetValue(hi->vptr, vlen, vll);
    }

    if (expireTime)
        *expireTime = hi->expire_time;
}

/* Get the field or value at iterator cursor, for an iterator on a hash value
 * encoded as a hash table. Prototype is similar to
 * `hashTypeGetFromHashTable`.
 *
 * expireTime - If parameter is not null, then the function will return the expire
 *              time of the field. If expiry not set, return EB_EXPIRE_TIME_INVALID
 */
void hashTypeCurrentFromHashTable(hashTypeIterator *hi, int what, char **str, size_t *len, uint64_t *expireTime) {
    serverAssert(hi->encoding == OBJ_ENCODING_HT);
    hfield key = NULL;

    if (what & OBJ_HASH_KEY) {
        key = dictGetKey(hi->de);
        *str = key;
        *len = hfieldlen(key);
    } else {
        sds val = dictGetVal(hi->de);
        *str = val;
        *len = sdslen(val);
    }

    if (expireTime)
        *expireTime = hi->expire_time;
}

/* Higher level function of hashTypeCurrent*() that returns the hash value
 * at current iterator position.
 *
 * The returned element is returned by reference in either *vstr and *vlen if
 * it's returned in string form, or stored in *vll if it's returned as
 * a number.
 *
 * If *vll is populated *vstr is set to NULL, so the caller
 * can always check the function return by checking the return value
 * type checking if vstr == NULL. */
void hashTypeCurrentObject(hashTypeIterator *hi,
                           int what,
                           unsigned char **vstr,
                           unsigned int *vlen,
                           long long *vll,
                           uint64_t *expireTime)
{
    if (hi->encoding == OBJ_ENCODING_LISTPACK ||
        hi->encoding == OBJ_ENCODING_LISTPACK_EX)
    {
        *vstr = NULL;
        hashTypeCurrentFromListpack(hi, what, vstr, vlen, vll, expireTime);
    } else if (hi->encoding == OBJ_ENCODING_HT) {
        char *ele;
        size_t eleLen;
        hashTypeCurrentFromHashTable(hi, what, &ele, &eleLen, expireTime);
        *vstr = (unsigned char*) ele;
        *vlen = eleLen;
    } else {
        serverPanic("Unknown hash encoding");
    }
}

/* Return the key or value at the current iterator position as a new
 * SDS string. */
sds hashTypeCurrentObjectNewSds(hashTypeIterator *hi, int what) {
    unsigned char *vstr;
    unsigned int vlen;
    long long vll;

    hashTypeCurrentObject(hi,what,&vstr,&vlen,&vll, NULL);
    if (vstr) return sdsnewlen(vstr,vlen);
    return sdsfromlonglong(vll);
}

/* Return the key at the current iterator position as a new hfield string. */
hfield hashTypeCurrentObjectNewHfield(hashTypeIterator *hi) {
    char buf[LONG_STR_SIZE];
    unsigned char *vstr;
    unsigned int vlen;
    long long vll;
    uint64_t expireTime;
    hfield hf;

    hashTypeCurrentObject(hi,OBJ_HASH_KEY,&vstr,&vlen,&vll, &expireTime);

    if (!vstr) {
        vlen = ll2string(buf, sizeof(buf), vll);
        vstr = (unsigned char *) buf;
    }

    hf = hfieldNew(vstr,vlen, expireTime != EB_EXPIRE_TIME_INVALID);
    return hf;
}

static robj *hashTypeLookupWriteOrCreate(client *c, robj *key) {
    robj *o = lookupKeyWrite(c->db,key);
    if (checkType(c,o,OBJ_HASH)) return NULL;

    if (o == NULL) {
        o = createHashObject();
        dbAdd(c->db,key,o);
    }
    return o;
}


void hashTypeConvertListpack(robj *o, int enc) {
    serverAssert(o->encoding == OBJ_ENCODING_LISTPACK);

    if (enc == OBJ_ENCODING_LISTPACK) {
        /* Nothing to do... */

    } else if (enc == OBJ_ENCODING_LISTPACK_EX) {
        unsigned char *p;

        /* Append HASH_LP_NO_TTL to each field name - value pair. */
        p = lpFirst(o->ptr);
        while (p != NULL) {
            p = lpNext(o->ptr, p);
            serverAssert(p);

            o->ptr = lpInsertInteger(o->ptr, HASH_LP_NO_TTL, p, LP_AFTER, &p);
            p = lpNext(o->ptr, p);
        }

        listpackEx *lpt = listpackExCreate();
        lpt->lp = o->ptr;
        o->encoding = OBJ_ENCODING_LISTPACK_EX;
        o->ptr = lpt;
    } else if (enc == OBJ_ENCODING_HT) {
        hashTypeIterator *hi;
        dict *dict;
        int ret;

        hi = hashTypeInitIterator(o);
        dict = dictCreate(&mstrHashDictType);

        /* Presize the dict to avoid rehashing */
        dictExpand(dict,hashTypeLength(o, 0));

        while (hashTypeNext(hi, 0) != C_ERR) {

            hfield key = hashTypeCurrentObjectNewHfield(hi);
            sds value = hashTypeCurrentObjectNewSds(hi,OBJ_HASH_VALUE);
            dictUseStoredKeyApi(dict, 1);
            ret = dictAdd(dict, key, value);
            dictUseStoredKeyApi(dict, 0);
            if (ret != DICT_OK) {
                hfieldFree(key); sdsfree(value); /* Needed for gcc ASAN */
                hashTypeReleaseIterator(hi);  /* Needed for gcc ASAN */
                serverLogHexDump(LL_WARNING,"listpack with dup elements dump",
                    o->ptr,lpBytes(o->ptr));
                serverPanic("Listpack corruption detected");
            }
        }
        hashTypeReleaseIterator(hi);
        zfree(o->ptr);
        o->encoding = OBJ_ENCODING_HT;
        o->ptr = dict;
    } else {
        serverPanic("Unknown hash encoding");
    }
}

void hashTypeConvertListpackEx(robj *o, int enc, ebuckets *hexpires) {
    serverAssert(o->encoding == OBJ_ENCODING_LISTPACK_EX);

    if (enc == OBJ_ENCODING_LISTPACK_EX) {
        return;
    } else if (enc == OBJ_ENCODING_HT) {
        int ret;
        hashTypeIterator *hi;
        dict *dict;
        dictExpireMetadata *dictExpireMeta;
        listpackEx *lpt = o->ptr;
        uint64_t minExpire = hashTypeGetMinExpire(o);

        if (hexpires && lpt->meta.trash != 1)
            ebRemove(hexpires, &hashExpireBucketsType, o);

        dict = dictCreate(&mstrHashDictTypeWithHFE);
        dictExpand(dict,hashTypeLength(o, 0));
        dictExpireMeta = (dictExpireMetadata *) dictMetadata(dict);

        /* Fillup dict HFE metadata */
        dictExpireMeta->key = lpt->key;       /* reference key in keyspace */
        dictExpireMeta->hfe = ebCreate();     /* Allocate HFE DS */
        dictExpireMeta->expireMeta.trash = 1; /* mark as trash (as long it wasn't ebAdd()) */

        hi = hashTypeInitIterator(o);

        while (hashTypeNext(hi, 0) != C_ERR) {
            hfield key = hashTypeCurrentObjectNewHfield(hi);
            sds value = hashTypeCurrentObjectNewSds(hi,OBJ_HASH_VALUE);
            dictUseStoredKeyApi(dict, 1);
            ret = dictAdd(dict, key, value);
            dictUseStoredKeyApi(dict, 0);
            if (ret != DICT_OK) {
                hfieldFree(key); sdsfree(value); /* Needed for gcc ASAN */
                hashTypeReleaseIterator(hi);  /* Needed for gcc ASAN */
                serverLogHexDump(LL_WARNING,"listpack with dup elements dump",
                                 lpt->lp,lpBytes(lpt->lp));
                serverPanic("Listpack corruption detected");
            }

            if (hi->expire_time != EB_EXPIRE_TIME_INVALID)
                ebAdd(&dictExpireMeta->hfe, &hashFieldExpireBucketsType, key, hi->expire_time);
        }
        hashTypeReleaseIterator(hi);
        listpackExFree(lpt);

        o->encoding = OBJ_ENCODING_HT;
        o->ptr = dict;

        if (hexpires && minExpire != EB_EXPIRE_TIME_INVALID)
            ebAdd(hexpires, &hashExpireBucketsType, o, minExpire);
    } else {
        serverPanic("Unknown hash encoding: %d", enc);
    }
}

/* NOTE: hexpires can be NULL (Won't register in global HFE DS) */
void hashTypeConvert(robj *o, int enc, ebuckets *hexpires) {
    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        hashTypeConvertListpack(o, enc);
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        hashTypeConvertListpackEx(o, enc, hexpires);
    } else if (o->encoding == OBJ_ENCODING_HT) {
        serverPanic("Not implemented");
    } else {
        serverPanic("Unknown hash encoding");
    }
}

/* This is a helper function for the COPY command.
 * Duplicate a hash object, with the guarantee that the returned object
 * has the same encoding as the original one.
 *
 * The resulting object always has refcount set to 1 */
robj *hashTypeDup(robj *o, sds newkey, uint64_t *minHashExpire) {
    robj *hobj;
    hashTypeIterator *hi;

    serverAssert(o->type == OBJ_HASH);

    if(o->encoding == OBJ_ENCODING_LISTPACK) {
        unsigned char *zl = o->ptr;
        size_t sz = lpBytes(zl);
        unsigned char *new_zl = zmalloc(sz);
        memcpy(new_zl, zl, sz);
        hobj = createObject(OBJ_HASH, new_zl);
        hobj->encoding = OBJ_ENCODING_LISTPACK;
    } else if(o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = o->ptr;

        if (lpt->meta.trash == 0)
            *minHashExpire = ebGetMetaExpTime(&lpt->meta);

        listpackEx *dup = listpackExCreate();
        dup->key = newkey;

        size_t sz = lpBytes(lpt->lp);
        dup->lp = lpNew(sz);
        memcpy(dup->lp, lpt->lp, sz);

        hobj = createObject(OBJ_HASH, dup);
        hobj->encoding = OBJ_ENCODING_LISTPACK_EX;
    } else if(o->encoding == OBJ_ENCODING_HT) {
        dictExpireMetadata *dictExpireMetaSrc, *dictExpireMetaDst = NULL;
        dict *d;

        /* If dict doesn't have HFE metadata, then create a new dict without it */
        if (!isDictWithMetaHFE(o->ptr)) {
            d = dictCreate(&mstrHashDictType);
        } else {
            /* Create a new dict with HFE metadata */
            d = dictCreate(&mstrHashDictTypeWithHFE);
            dictExpireMetaSrc = (dictExpireMetadata *) dictMetadata((dict *) o->ptr);
            dictExpireMetaDst = (dictExpireMetadata *) dictMetadata(d);
            dictExpireMetaDst->key = newkey;         /* reference key in keyspace */
            dictExpireMetaDst->hfe = ebCreate();     /* Allocate HFE DS */
            dictExpireMetaDst->expireMeta.trash = 1; /* mark as trash (as long it wasn't ebAdd()) */

            /* Extract the minimum expire time of the source hash (Will be used by caller
             * to register the new hash in the global ebuckets, i.e db->hexpires) */
            if (dictExpireMetaSrc->expireMeta.trash == 0)
                *minHashExpire = ebGetMetaExpTime(&dictExpireMetaSrc->expireMeta);
        }
        dictExpand(d, dictSize((const dict*)o->ptr));

        hi = hashTypeInitIterator(o);
        while (hashTypeNext(hi, 0) != C_ERR) {
            uint64_t expireTime;
            sds newfield, newvalue;
            /* Extract a field-value pair from an original hash object.*/
            char *field, *value;
            size_t fieldLen, valueLen;
            hashTypeCurrentFromHashTable(hi, OBJ_HASH_KEY, &field, &fieldLen, &expireTime);
            if (expireTime == EB_EXPIRE_TIME_INVALID) {
                newfield = hfieldNew(field, fieldLen, 0);
            } else {
                newfield = hfieldNew(field, fieldLen, 1);
                ebAdd(&dictExpireMetaDst->hfe, &hashFieldExpireBucketsType, newfield, expireTime);
            }

            hashTypeCurrentFromHashTable(hi, OBJ_HASH_VALUE, &value, &valueLen, NULL);
            newvalue = sdsnewlen(value, valueLen);

            /* Add a field-value pair to a new hash object. */
            dictUseStoredKeyApi(d, 1);
            dictAdd(d,newfield,newvalue);
            dictUseStoredKeyApi(d, 0);
        }
        hashTypeReleaseIterator(hi);

        hobj = createObject(OBJ_HASH, d);
        hobj->encoding = OBJ_ENCODING_HT;
    } else {
        serverPanic("Unknown hash encoding");
    }
    return hobj;
}

/* Create a new sds string from the listpack entry. */
sds hashSdsFromListpackEntry(listpackEntry *e) {
    return e->sval ? sdsnewlen(e->sval, e->slen) : sdsfromlonglong(e->lval);
}

/* Reply with bulk string from the listpack entry. */
void hashReplyFromListpackEntry(client *c, listpackEntry *e) {
    if (e->sval)
        addReplyBulkCBuffer(c, e->sval, e->slen);
    else
        addReplyBulkLongLong(c, e->lval);
}

/* Return random element from a non empty hash.
 * 'key' and 'val' will be set to hold the element.
 * The memory in them is not to be freed or modified by the caller.
 * 'val' can be NULL in which case it's not extracted. */
void hashTypeRandomElement(robj *hashobj, unsigned long hashsize, listpackEntry *key, listpackEntry *val) {
    if (hashobj->encoding == OBJ_ENCODING_HT) {
        dictEntry *de = dictGetFairRandomKey(hashobj->ptr);
        hfield field = dictGetKey(de);
        key->sval = (unsigned char*)field;
        key->slen = hfieldlen(field);
        if (val) {
            sds s = dictGetVal(de);
            val->sval = (unsigned char*)s;
            val->slen = sdslen(s);
        }
    } else if (hashobj->encoding == OBJ_ENCODING_LISTPACK) {
        lpRandomPair(hashobj->ptr, hashsize, key, val, 2);
    } else if (hashobj->encoding == OBJ_ENCODING_LISTPACK_EX) {
        lpRandomPair(hashTypeListpackGetLp(hashobj), hashsize, key, val, 3);
    } else {
        serverPanic("Unknown hash encoding");
    }
}

/*
 * Active expiration of fields in hash
 *
 * Called by hashTypeDbActiveExpire() for each hash registered in the HFE DB
 * (db->hexpires) with an expiration-time less than or equal current time.
 *
 * This callback performs the following actions for each hash:
 * - Delete expired fields as by calling ebExpire(hash)
 * - If afterward there are future fields to expire, it will update the hash in
 *   HFE DB with the next hash-field minimum expiration time by returning
 *   ACT_UPDATE_EXP_ITEM.
 * - If the hash has no more fields to expire, it is removed from the HFE DB
 *   by returning ACT_REMOVE_EXP_ITEM.
 * - If hash has no more fields afterward, it will remove the hash from keyspace.
 */
static ExpireAction hashTypeActiveExpire(eItem _hashObj, void *ctx) {
    robj *hashObj = (robj *) _hashObj;
    ActiveExpireCtx *activeExpireCtx = (ActiveExpireCtx *) ctx;
    sds keystr = NULL;
    ExpireInfo info = {0};

    /* If no more quota left for this callback, stop */
    if (activeExpireCtx->fieldsToExpireQuota == 0)
        return ACT_STOP_ACTIVE_EXP;

    if (hashObj->encoding == OBJ_ENCODING_LISTPACK_EX) {
        info = (ExpireInfo){
                .maxToExpire = activeExpireCtx->fieldsToExpireQuota,
                .now = commandTimeSnapshot(),
                .itemsExpired = 0};

        listpackExExpire(activeExpireCtx->db, hashObj, &info);
        server.stat_expired_hash_fields += info.itemsExpired;
        keystr = ((listpackEx*)hashObj->ptr)->key;
    } else {
        serverAssert(hashObj->encoding == OBJ_ENCODING_HT);

        dict *d = hashObj->ptr;
        dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *) dictMetadata(d);

        OnFieldExpireCtx onFieldExpireCtx = {
            .hashObj = hashObj,
            .db = activeExpireCtx->db
        };

        info = (ExpireInfo){
            .maxToExpire = activeExpireCtx->fieldsToExpireQuota,
            .onExpireItem = onFieldExpire,
            .ctx = &onFieldExpireCtx,
            .now = commandTimeSnapshot()
        };

        ebExpire(&dictExpireMeta->hfe, &hashFieldExpireBucketsType, &info);
        keystr = dictExpireMeta->key;
    }

    /* Update quota left */
    activeExpireCtx->fieldsToExpireQuota -= info.itemsExpired;

    /* If hash has no more fields to expire, remove it from HFE DB */
    if (info.nextExpireTime == 0) {
        if (hashTypeLength(hashObj, 0) == 0) {
            robj *key = createStringObject(keystr, sdslen(keystr));
            dbDelete(activeExpireCtx->db, key);
            notifyKeyspaceEvent(NOTIFY_GENERIC,"del",key, activeExpireCtx->db->id);
            server.dirty++;
            signalModifiedKey(NULL, &server.db[0], key);
            decrRefCount(key);
        }
        return ACT_REMOVE_EXP_ITEM;
    } else {
        /* Hash has more fields to expire. Keep hash to pending items that will
         * be added back to global HFE DS at the end of ebExpire() */
        ExpireMeta *expireMeta = hashGetExpireMeta(hashObj);
        ebSetMetaExpTime(expireMeta, info.nextExpireTime);
        return ACT_UPDATE_EXP_ITEM;
    }
}

/* Return the next/minimum expiry time of the hash-field. This is useful if a
 * field with the minimum expiry is deleted, and you want to get the next
 * minimum expiry. Otherwise, consider using hashTypeGetMinExpire() which will
 * be faster. If there is no field with expiry, returns EB_EXPIRE_TIME_INVALID */
uint64_t hashTypeGetNextTimeToExpire(robj *o) {
    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        return EB_EXPIRE_TIME_INVALID;
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        return listpackExGetMinExpire(o);
    } else {
        serverAssert(o->encoding == OBJ_ENCODING_HT);

        dict *d = o->ptr;
        if (!isDictWithMetaHFE(d))
            return EB_EXPIRE_TIME_INVALID;

        dictExpireMetadata *expireMeta = (dictExpireMetadata *) dictMetadata(d);
        return ebGetNextTimeToExpire(expireMeta->hfe, &hashFieldExpireBucketsType);
    }
}

/* Return the next/minimum expiry time of the hash-field.
 * If not found, return EB_EXPIRE_TIME_INVALID */
uint64_t hashTypeGetMinExpire(robj *o) {
    ExpireMeta *expireMeta = NULL;

    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        return EB_EXPIRE_TIME_INVALID;
    } else if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = o->ptr;
        expireMeta = &lpt->meta;
    } else {
        serverAssert(o->encoding == OBJ_ENCODING_HT);

        dict *d = o->ptr;
        if (!isDictWithMetaHFE(d))
            return EB_EXPIRE_TIME_INVALID;

        expireMeta = &((dictExpireMetadata *) dictMetadata(d))->expireMeta;
    }

    /* Keep aside next hash-field expiry before updating HFE DS. Verify it is not trash */
    if (expireMeta->trash == 1)
        return EB_EXPIRE_TIME_INVALID;

    return ebGetMetaExpTime(expireMeta);
}

uint64_t hashTypeRemoveFromExpires(ebuckets *hexpires, robj *o) {
    if (o->encoding == OBJ_ENCODING_LISTPACK) {
        return EB_EXPIRE_TIME_INVALID;
    } else if (o->encoding == OBJ_ENCODING_HT) {
        /* If dict doesn't holds HFE metadata */
        if (!isDictWithMetaHFE(o->ptr))
            return EB_EXPIRE_TIME_INVALID;
    }

    uint64_t expireTime = ebGetExpireTime(&hashExpireBucketsType, o);

    /* If registered in global HFE DS then remove it (not trash) */
    if (expireTime != EB_EXPIRE_TIME_INVALID)
        ebRemove(hexpires, &hashExpireBucketsType, o);

    return expireTime;
}

/* Add hash to global HFE DS and update key for notifications.
 *
 * key         - must be the same key instance that is persisted in db->dict
 * expireTime  - expiration in msec.
 *               If eq. 0 then the hash will be added to the global HFE DS with
 *               the minimum expiration time that is already written in advance
 *               to attached metadata (which considered as trash as long as it is
 *               not attached to global HFE DS).
 *
 * Precondition: It is a hash of type listpackex or HT with HFE metadata.
 */
void hashTypeAddToExpires(redisDb *db, sds key, robj *hashObj, uint64_t expireTime) {
    if (expireTime > EB_EXPIRE_TIME_MAX)
         return;

    if (hashObj->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = hashObj->ptr;
        lpt->key = key;
        expireTime = (expireTime) ? expireTime : ebGetMetaExpTime(&lpt->meta);
        ebAdd(&db->hexpires, &hashExpireBucketsType, hashObj, expireTime);
    } else if (hashObj->encoding == OBJ_ENCODING_HT) {
        dict *d = hashObj->ptr;
        if (isDictWithMetaHFE(d)) {
            dictExpireMetadata *meta = (dictExpireMetadata *) dictMetadata(d);
            expireTime = (expireTime) ? expireTime : ebGetMetaExpTime(&meta->expireMeta);
            meta->key = key;
            ebAdd(&db->hexpires, &hashExpireBucketsType, hashObj, expireTime);
        }
    }
}

/* DB active expire and update hashes with time-expiration on fields.
 *
 * The callback function hashTypeActiveExpire() is invoked for each hash registered
 * in the HFE DB (db->expires) with an expiration-time less than or equal to the
 * current time. This callback performs the following actions for each hash:
 * - If the hash has one or more fields to expire, it will delete those fields.
 * - If there are more fields to expire, it will update the hash with the next
 *   expiration time in HFE DB.
 * - If the hash has no more fields to expire, it is removed from the HFE DB.
 * - If the hash has no more fields, it is removed from the main DB.
 *
 * Returns number of fields active-expired.
 */
uint64_t hashTypeDbActiveExpire(redisDb *db, uint32_t maxFieldsToExpire) {
    ActiveExpireCtx ctx = { .db = db, .fieldsToExpireQuota = maxFieldsToExpire };
    ExpireInfo info = {
            .maxToExpire = UINT64_MAX, /* Only maxFieldsToExpire play a role */
            .onExpireItem = hashTypeActiveExpire,
            .ctx = &ctx,
            .now = commandTimeSnapshot(),
            .itemsExpired = 0};

    ebExpire(&db->hexpires, &hashExpireBucketsType, &info);

    /* Return number of fields active-expired */
    return maxFieldsToExpire - ctx.fieldsToExpireQuota;
}

void hashTypeFree(robj *o) {
    switch (o->encoding) {
        case OBJ_ENCODING_HT:
            /* Verify hash is not registered in global HFE ds */
            if (isDictWithMetaHFE((dict*)o->ptr)) {
                dictExpireMetadata *m = (dictExpireMetadata *)dictMetadata((dict*)o->ptr);
                serverAssert(m->expireMeta.trash == 1);
            }
            dictRelease((dict*) o->ptr);
            break;
        case OBJ_ENCODING_LISTPACK:
            lpFree(o->ptr);
            break;
        case OBJ_ENCODING_LISTPACK_EX:
            /* Verify hash is not registered in global HFE ds */
            serverAssert(((listpackEx *) o->ptr)->meta.trash == 1);
            listpackExFree(o->ptr);
            break;
        default:
            serverPanic("Unknown hash encoding type");
            break;
    }
}

/* Attempts to update the reference to the new key. Now it's only used in defrag. */
void hashTypeUpdateKeyRef(robj *o, sds newkey) {
    if (o->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = o->ptr;
        lpt->key = newkey;
    } else if (o->encoding == OBJ_ENCODING_HT && isDictWithMetaHFE(o->ptr)) {
        dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *)dictMetadata((dict*)o->ptr);
        dictExpireMeta->key = newkey;
    } else {
        /* Nothing to do. */
    }
}

ebuckets *hashTypeGetDictMetaHFE(dict *d) {
    dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *) dictMetadata(d);
    return &dictExpireMeta->hfe;
}

/*-----------------------------------------------------------------------------
 * Hash type commands
 *----------------------------------------------------------------------------*/

void hsetnxCommand(client *c) {
    int isHashDeleted;
    robj *o;
    if ((o = hashTypeLookupWriteOrCreate(c,c->argv[1])) == NULL) return;

    if (hashTypeExists(c->db, o, c->argv[2]->ptr, &isHashDeleted)) {
        addReply(c, shared.czero);
        return;
    }

    /* Field expired and in turn hash deleted. Create new one! */
    if (isHashDeleted) {
        o = createHashObject();
        dbAdd(c->db,c->argv[1],o);
    }

    hashTypeTryConversion(c->db, o,c->argv,2,3);
    hashTypeSet(c->db, o,c->argv[2]->ptr,c->argv[3]->ptr,HASH_SET_COPY);
    addReply(c, shared.cone);
    signalModifiedKey(c,c->db,c->argv[1]);
    notifyKeyspaceEvent(NOTIFY_HASH,"hset",c->argv[1],c->db->id);
    server.dirty++;
}

void hsetCommand(client *c) {
    int i, created = 0;
    robj *o;

    if ((c->argc % 2) == 1) {
        addReplyErrorArity(c);
        return;
    }

    if ((o = hashTypeLookupWriteOrCreate(c,c->argv[1])) == NULL) return;
    hashTypeTryConversion(c->db,o,c->argv,2,c->argc-1);

    for (i = 2; i < c->argc; i += 2)
        created += !hashTypeSet(c->db, o,c->argv[i]->ptr,c->argv[i+1]->ptr,HASH_SET_COPY);

    /* HMSET (deprecated) and HSET return value is different. */
    char *cmdname = c->argv[0]->ptr;
    if (cmdname[1] == 's' || cmdname[1] == 'S') {
        /* HSET */
        addReplyLongLong(c, created);
    } else {
        /* HMSET */
        addReply(c, shared.ok);
    }
    signalModifiedKey(c,c->db,c->argv[1]);
    notifyKeyspaceEvent(NOTIFY_HASH,"hset",c->argv[1],c->db->id);
    server.dirty += (c->argc - 2)/2;
}

void hincrbyCommand(client *c) {
    long long value, incr, oldvalue;
    robj *o;
    sds new;
    unsigned char *vstr;
    unsigned int vlen;

    if (getLongLongFromObjectOrReply(c,c->argv[3],&incr,NULL) != C_OK) return;
    if ((o = hashTypeLookupWriteOrCreate(c,c->argv[1])) == NULL) return;

    GetFieldRes res = hashTypeGetValue(c->db,o,c->argv[2]->ptr,&vstr,&vlen,&value);
    if (res == GETF_OK) {
        if (vstr) {
            if (string2ll((char*)vstr,vlen,&value) == 0) {
                addReplyError(c,"hash value is not an integer");
                return;
            }
        } /* Else hashTypeGetValue() already stored it into &value */
    } else if ((res == GETF_NOT_FOUND) || (res == GETF_EXPIRED)) {
        value = 0;
    } else {
        /* Field expired and in turn hash deleted. Create new one! */
        o = createHashObject();
        dbAdd(c->db,c->argv[1],o);
        value = 0;
    }

    oldvalue = value;
    if ((incr < 0 && oldvalue < 0 && incr < (LLONG_MIN-oldvalue)) ||
        (incr > 0 && oldvalue > 0 && incr > (LLONG_MAX-oldvalue))) {
        addReplyError(c,"increment or decrement would overflow");
        return;
    }
    value += incr;
    new = sdsfromlonglong(value);
    hashTypeSet(c->db, o,c->argv[2]->ptr,new,HASH_SET_TAKE_VALUE | HASH_SET_KEEP_FIELD);
    addReplyLongLong(c,value);
    signalModifiedKey(c,c->db,c->argv[1]);
    notifyKeyspaceEvent(NOTIFY_HASH,"hincrby",c->argv[1],c->db->id);
    server.dirty++;
}

void hincrbyfloatCommand(client *c) {
    long double value, incr;
    long long ll;
    robj *o;
    sds new;
    unsigned char *vstr;
    unsigned int vlen;

    if (getLongDoubleFromObjectOrReply(c,c->argv[3],&incr,NULL) != C_OK) return;
    if (isnan(incr) || isinf(incr)) {
        addReplyError(c,"value is NaN or Infinity");
        return;
    }
    if ((o = hashTypeLookupWriteOrCreate(c,c->argv[1])) == NULL) return;
    GetFieldRes res = hashTypeGetValue(c->db, o,c->argv[2]->ptr,&vstr,&vlen,&ll);
    if (res == GETF_OK) {
        if (vstr) {
            if (string2ld((char*)vstr,vlen,&value) == 0) {
                addReplyError(c,"hash value is not a float");
                return;
            }
        } else {
            value = (long double)ll;
        }
    } else if ((res == GETF_NOT_FOUND) || (res == GETF_EXPIRED)) {
        value = 0;
    } else {
        /* Field expired and in turn hash deleted. Create new one! */
        o = createHashObject();
        dbAdd(c->db,c->argv[1],o);
        value = 0;
    }

    value += incr;
    if (isnan(value) || isinf(value)) {
        addReplyError(c,"increment would produce NaN or Infinity");
        return;
    }

    char buf[MAX_LONG_DOUBLE_CHARS];
    int len = ld2string(buf,sizeof(buf),value,LD_STR_HUMAN);
    new = sdsnewlen(buf,len);
    hashTypeSet(c->db, o,c->argv[2]->ptr,new,HASH_SET_TAKE_VALUE | HASH_SET_KEEP_FIELD);
    addReplyBulkCBuffer(c,buf,len);
    signalModifiedKey(c,c->db,c->argv[1]);
    notifyKeyspaceEvent(NOTIFY_HASH,"hincrbyfloat",c->argv[1],c->db->id);
    server.dirty++;

    /* Always replicate HINCRBYFLOAT as an HSET command with the final value
     * in order to make sure that differences in float precision or formatting
     * will not create differences in replicas or after an AOF restart. */
    robj *newobj;
    newobj = createRawStringObject(buf,len);
    rewriteClientCommandArgument(c,0,shared.hset);
    rewriteClientCommandArgument(c,3,newobj);
    decrRefCount(newobj);
}

static GetFieldRes addHashFieldToReply(client *c, robj *o, sds field) {
    if (o == NULL) {
        addReplyNull(c);
        return GETF_NOT_FOUND;
    }

    unsigned char *vstr = NULL;
    unsigned int vlen = UINT_MAX;
    long long vll = LLONG_MAX;

    GetFieldRes res = hashTypeGetValue(c->db, o, field, &vstr, &vlen, &vll);
    if (res == GETF_OK) {
        if (vstr) {
            addReplyBulkCBuffer(c, vstr, vlen);
        } else {
            addReplyBulkLongLong(c, vll);
        }
    } else {
        addReplyNull(c);
    }
    return res;
}

void hgetCommand(client *c) {
    robj *o;

    if ((o = lookupKeyReadOrReply(c,c->argv[1],shared.null[c->resp])) == NULL ||
        checkType(c,o,OBJ_HASH)) return;

    addHashFieldToReply(c, o, c->argv[2]->ptr);
}

void hmgetCommand(client *c) {
    GetFieldRes res = GETF_OK;
    robj *o;
    int i;

    /* Don't abort when the key cannot be found. Non-existing keys are empty
     * hashes, where HMGET should respond with a series of null bulks. */
    o = lookupKeyRead(c->db, c->argv[1]);
    if (checkType(c,o,OBJ_HASH)) return;

    addReplyArrayLen(c, c->argc-2);
    for (i = 2; i < c->argc ; i++) {

        res = addHashFieldToReply(c, o, c->argv[i]->ptr);

        /* If hash got lazy expired since all fields are expired (o is invalid),
         * then fill the rest with trivial nulls and return */
        if (res == GETF_EXPIRED_HASH) {
            while (++i < c->argc)
                addReplyNull(c);
            return;
        }
    }
}

void hdelCommand(client *c) {
    robj *o;
    int j, deleted = 0, keyremoved = 0;

    if ((o = lookupKeyWriteOrReply(c,c->argv[1],shared.czero)) == NULL ||
        checkType(c,o,OBJ_HASH)) return;

    for (j = 2; j < c->argc; j++) {
        if (hashTypeDelete(o,c->argv[j]->ptr,1)) {
            deleted++;
            if (hashTypeLength(o, 0) == 0) {
                dbDelete(c->db,c->argv[1]);
                keyremoved = 1;
                break;
            }
        }
    }
    if (deleted) {
        signalModifiedKey(c,c->db,c->argv[1]);
        notifyKeyspaceEvent(NOTIFY_HASH,"hdel",c->argv[1],c->db->id);
        if (keyremoved)
            notifyKeyspaceEvent(NOTIFY_GENERIC,"del",c->argv[1],
                                c->db->id);
        server.dirty += deleted;
    }
    addReplyLongLong(c,deleted);
}

void hlenCommand(client *c) {
    robj *o;

    if ((o = lookupKeyReadOrReply(c,c->argv[1],shared.czero)) == NULL ||
        checkType(c,o,OBJ_HASH)) return;

    addReplyLongLong(c,hashTypeLength(o, 0));
}

void hstrlenCommand(client *c) {
    robj *o;
    unsigned char *vstr = NULL;
    unsigned int vlen = UINT_MAX;
    long long vll = LLONG_MAX;

    if ((o = lookupKeyReadOrReply(c,c->argv[1],shared.czero)) == NULL ||
        checkType(c,o,OBJ_HASH)) return;

    GetFieldRes res = hashTypeGetValue(c->db, o, c->argv[2]->ptr, &vstr, &vlen, &vll);

    if (res == GETF_NOT_FOUND || res == GETF_EXPIRED || res == GETF_EXPIRED_HASH) {
        addReply(c, shared.czero);
        return;
    }

    size_t len = vstr ? vlen : sdigits10(vll);
    addReplyLongLong(c,len);
}

static void addHashIteratorCursorToReply(client *c, hashTypeIterator *hi, int what) {
    if (hi->encoding == OBJ_ENCODING_LISTPACK ||
        hi->encoding == OBJ_ENCODING_LISTPACK_EX)
    {
        unsigned char *vstr = NULL;
        unsigned int vlen = UINT_MAX;
        long long vll = LLONG_MAX;

        hashTypeCurrentFromListpack(hi, what, &vstr, &vlen, &vll, NULL);
        if (vstr)
            addReplyBulkCBuffer(c, vstr, vlen);
        else
            addReplyBulkLongLong(c, vll);
    } else if (hi->encoding == OBJ_ENCODING_HT) {
        char *value;
        size_t len;
        hashTypeCurrentFromHashTable(hi, what, &value, &len, NULL);
        addReplyBulkCBuffer(c, value, len);
    } else {
        serverPanic("Unknown hash encoding");
    }
}

void genericHgetallCommand(client *c, int flags) {
    robj *o;
    hashTypeIterator *hi;
    int length, count = 0;

    robj *emptyResp = (flags & OBJ_HASH_KEY && flags & OBJ_HASH_VALUE) ?
        shared.emptymap[c->resp] : shared.emptyarray;
    if ((o = lookupKeyReadOrReply(c,c->argv[1],emptyResp))
        == NULL || checkType(c,o,OBJ_HASH)) return;

    /* We return a map if the user requested keys and values, like in the
     * HGETALL case. Otherwise to use a flat array makes more sense. */
    length = hashTypeLength(o, 1 /*subtractExpiredFields*/);
    if (flags & OBJ_HASH_KEY && flags & OBJ_HASH_VALUE) {
        addReplyMapLen(c, length);
    } else {
        addReplyArrayLen(c, length);
    }

    hi = hashTypeInitIterator(o);

    /* Skip expired fields if the hash has an expire time set at global HFE DS. We could
     * set it to constant 1, but then it will make another lookup for each field expiration */
    int skipExpiredFields = (EB_EXPIRE_TIME_INVALID == hashTypeGetMinExpire(o)) ? 0 : 1;

    while (hashTypeNext(hi, skipExpiredFields) != C_ERR) {
        if (flags & OBJ_HASH_KEY) {
            addHashIteratorCursorToReply(c, hi, OBJ_HASH_KEY);
            count++;
        }
        if (flags & OBJ_HASH_VALUE) {
            addHashIteratorCursorToReply(c, hi, OBJ_HASH_VALUE);
            count++;
        }
    }

    hashTypeReleaseIterator(hi);

    /* Make sure we returned the right number of elements. */
    if (flags & OBJ_HASH_KEY && flags & OBJ_HASH_VALUE) count /= 2;
    serverAssert(count == length);
}

void hkeysCommand(client *c) {
    genericHgetallCommand(c,OBJ_HASH_KEY);
}

void hvalsCommand(client *c) {
    genericHgetallCommand(c,OBJ_HASH_VALUE);
}

void hgetallCommand(client *c) {
    genericHgetallCommand(c,OBJ_HASH_KEY|OBJ_HASH_VALUE);
}

void hexistsCommand(client *c) {
    robj *o;
    int isHashDeleted;
    if ((o = lookupKeyReadOrReply(c,c->argv[1],shared.czero)) == NULL ||
        checkType(c,o,OBJ_HASH)) return;

    addReply(c,hashTypeExists(c->db,o,c->argv[2]->ptr,&isHashDeleted) ? shared.cone : shared.czero);
}

void hscanCommand(client *c) {
    robj *o;
    unsigned long long cursor;

    if (parseScanCursorOrReply(c,c->argv[2],&cursor) == C_ERR) return;
    if ((o = lookupKeyReadOrReply(c,c->argv[1],shared.emptyscan)) == NULL ||
        checkType(c,o,OBJ_HASH)) return;

    scanGenericCommand(c,o,cursor);
}

static void hrandfieldReplyWithListpack(client *c, unsigned int count, listpackEntry *keys, listpackEntry *vals) {
    for (unsigned long i = 0; i < count; i++) {
        if (vals && c->resp > 2)
            addReplyArrayLen(c,2);
        if (keys[i].sval)
            addReplyBulkCBuffer(c, keys[i].sval, keys[i].slen);
        else
            addReplyBulkLongLong(c, keys[i].lval);
        if (vals) {
            if (vals[i].sval)
                addReplyBulkCBuffer(c, vals[i].sval, vals[i].slen);
            else
                addReplyBulkLongLong(c, vals[i].lval);
        }
    }
}

/* How many times bigger should be the hash compared to the requested size
 * for us to not use the "remove elements" strategy? Read later in the
 * implementation for more info. */
#define HRANDFIELD_SUB_STRATEGY_MUL 3

/* If client is trying to ask for a very large number of random elements,
 * queuing may consume an unlimited amount of memory, so we want to limit
 * the number of randoms per time. */
#define HRANDFIELD_RANDOM_SAMPLE_LIMIT 1000

void hrandfieldWithCountCommand(client *c, long l, int withvalues) {
    unsigned long count, size;
    int uniq = 1;
    robj *hash;

    if ((hash = lookupKeyReadOrReply(c,c->argv[1],shared.emptyarray))
        == NULL || checkType(c,hash,OBJ_HASH)) return;
    /* TODO: Active-expire */
    size = hashTypeLength(hash, 0);

    if(l >= 0) {
        count = (unsigned long) l;
    } else {
        count = -l;
        uniq = 0;
    }

    /* If count is zero, serve it ASAP to avoid special cases later. */
    if (count == 0) {
        addReply(c,shared.emptyarray);
        return;
    }

    /* CASE 1: The count was negative, so the extraction method is just:
     * "return N random elements" sampling the whole set every time.
     * This case is trivial and can be served without auxiliary data
     * structures. This case is the only one that also needs to return the
     * elements in random order. */
    if (!uniq || count == 1) {
        if (withvalues && c->resp == 2)
            addReplyArrayLen(c, count*2);
        else
            addReplyArrayLen(c, count);
        if (hash->encoding == OBJ_ENCODING_HT) {
            while (count--) {
                dictEntry *de = dictGetFairRandomKey(hash->ptr);
                hfield field = dictGetKey(de);
                sds value = dictGetVal(de);
                if (withvalues && c->resp > 2)
                    addReplyArrayLen(c,2);
                addReplyBulkCBuffer(c, field, hfieldlen(field));
                if (withvalues)
                    addReplyBulkCBuffer(c, value, sdslen(value));
                if (c->flags & CLIENT_CLOSE_ASAP)
                    break;
            }
        } else if (hash->encoding == OBJ_ENCODING_LISTPACK ||
                   hash->encoding == OBJ_ENCODING_LISTPACK_EX)
        {
            listpackEntry *keys, *vals = NULL;
            unsigned long limit, sample_count;
            unsigned char *lp = hashTypeListpackGetLp(hash);
            int tuple_len = hash->encoding == OBJ_ENCODING_LISTPACK ? 2 : 3;

            limit = count > HRANDFIELD_RANDOM_SAMPLE_LIMIT ? HRANDFIELD_RANDOM_SAMPLE_LIMIT : count;
            keys = zmalloc(sizeof(listpackEntry)*limit);
            if (withvalues)
                vals = zmalloc(sizeof(listpackEntry)*limit);
            while (count) {
                sample_count = count > limit ? limit : count;
                count -= sample_count;
                lpRandomPairs(lp, sample_count, keys, vals, tuple_len);
                hrandfieldReplyWithListpack(c, sample_count, keys, vals);
                if (c->flags & CLIENT_CLOSE_ASAP)
                    break;
            }
            zfree(keys);
            zfree(vals);
        }
        return;
    }

    /* Initiate reply count, RESP3 responds with nested array, RESP2 with flat one. */
    long reply_size = count < size ? count : size;
    if (withvalues && c->resp == 2)
        addReplyArrayLen(c, reply_size*2);
    else
        addReplyArrayLen(c, reply_size);

    /* CASE 2:
    * The number of requested elements is greater than the number of
    * elements inside the hash: simply return the whole hash. */
    if(count >= size) {
        hashTypeIterator *hi = hashTypeInitIterator(hash);
        while (hashTypeNext(hi, 0) != C_ERR) {
            if (withvalues && c->resp > 2)
                addReplyArrayLen(c,2);
            addHashIteratorCursorToReply(c, hi, OBJ_HASH_KEY);
            if (withvalues)
                addHashIteratorCursorToReply(c, hi, OBJ_HASH_VALUE);
        }
        hashTypeReleaseIterator(hi);
        return;
    }

    /* CASE 2.5 listpack only. Sampling unique elements, in non-random order.
     * Listpack encoded hashes are meant to be relatively small, so
     * HRANDFIELD_SUB_STRATEGY_MUL isn't necessary and we rather not make
     * copies of the entries. Instead, we emit them directly to the output
     * buffer.
     *
     * And it is inefficient to repeatedly pick one random element from a
     * listpack in CASE 4. So we use this instead. */
    if (hash->encoding == OBJ_ENCODING_LISTPACK ||
        hash->encoding == OBJ_ENCODING_LISTPACK_EX)
    {
        unsigned char *lp = hashTypeListpackGetLp(hash);
        int tuple_len = hash->encoding == OBJ_ENCODING_LISTPACK ? 2 : 3;
        listpackEntry *keys, *vals = NULL;
        keys = zmalloc(sizeof(listpackEntry)*count);
        if (withvalues)
            vals = zmalloc(sizeof(listpackEntry)*count);
        serverAssert(lpRandomPairsUnique(lp, count, keys, vals, tuple_len) == count);
        hrandfieldReplyWithListpack(c, count, keys, vals);
        zfree(keys);
        zfree(vals);
        return;
    }

    /* CASE 3:
     * The number of elements inside the hash is not greater than
     * HRANDFIELD_SUB_STRATEGY_MUL times the number of requested elements.
     * In this case we create a hash from scratch with all the elements, and
     * subtract random elements to reach the requested number of elements.
     *
     * This is done because if the number of requested elements is just
     * a bit less than the number of elements in the hash, the natural approach
     * used into CASE 4 is highly inefficient. */
    if (count*HRANDFIELD_SUB_STRATEGY_MUL > size) {
        /* Hashtable encoding (generic implementation) */
        dict *d = dictCreate(&sdsReplyDictType);  /* without metadata! */
        dictExpand(d, size);
        hashTypeIterator *hi = hashTypeInitIterator(hash);

        /* Add all the elements into the temporary dictionary. */
        while ((hashTypeNext(hi, 0)) != C_ERR) {
            int ret = DICT_ERR;
            sds key, value = NULL;

            key = hashTypeCurrentObjectNewSds(hi,OBJ_HASH_KEY);
            if (withvalues)
                value = hashTypeCurrentObjectNewSds(hi,OBJ_HASH_VALUE);
            ret = dictAdd(d, key, value);

            serverAssert(ret == DICT_OK);
        }
        serverAssert(dictSize(d) == size);
        hashTypeReleaseIterator(hi);

        /* Remove random elements to reach the right count. */
        while (size > count) {
            dictEntry *de;
            de = dictGetFairRandomKey(d);
            dictUseStoredKeyApi(d, 1);
            dictUnlink(d,dictGetKey(de));
            dictUseStoredKeyApi(d, 0);
            sdsfree(dictGetKey(de));
            sdsfree(dictGetVal(de));
            dictFreeUnlinkedEntry(d,de);
            size--;
        }

        /* Reply with what's in the dict and release memory */
        dictIterator *di;
        dictEntry *de;
        di = dictGetIterator(d);
        while ((de = dictNext(di)) != NULL) {
            sds key = dictGetKey(de);
            sds value = dictGetVal(de);
            if (withvalues && c->resp > 2)
                addReplyArrayLen(c,2);
            addReplyBulkSds(c, key);
            if (withvalues)
                addReplyBulkSds(c, value);
        }

        dictReleaseIterator(di);
        dictRelease(d);
    }

    /* CASE 4: We have a big hash compared to the requested number of elements.
     * In this case we can simply get random elements from the hash and add
     * to the temporary hash, trying to eventually get enough unique elements
     * to reach the specified count. */
    else {
        /* Hashtable encoding (generic implementation) */
        unsigned long added = 0;
        listpackEntry key, value;
        dict *d = dictCreate(&hashDictType);
        dictExpand(d, count);
        while(added < count) {
            hashTypeRandomElement(hash, size, &key, withvalues? &value : NULL);

            /* Try to add the object to the dictionary. If it already exists
            * free it, otherwise increment the number of objects we have
            * in the result dictionary. */
            sds skey = hashSdsFromListpackEntry(&key);
            if (dictAdd(d,skey,NULL) != DICT_OK) {
                sdsfree(skey);
                continue;
            }
            added++;

            /* We can reply right away, so that we don't need to store the value in the dict. */
            if (withvalues && c->resp > 2)
                addReplyArrayLen(c,2);
            hashReplyFromListpackEntry(c, &key);
            if (withvalues)
                hashReplyFromListpackEntry(c, &value);
        }

        /* Release memory */
        dictRelease(d);
    }
}

/* HRANDFIELD key [<count> [WITHVALUES]] */
void hrandfieldCommand(client *c) {
    long l;
    int withvalues = 0;
    robj *hash;
    listpackEntry ele;

    if (c->argc >= 3) {
        if (getRangeLongFromObjectOrReply(c,c->argv[2],-LONG_MAX,LONG_MAX,&l,NULL) != C_OK) return;
        if (c->argc > 4 || (c->argc == 4 && strcasecmp(c->argv[3]->ptr,"withvalues"))) {
            addReplyErrorObject(c,shared.syntaxerr);
            return;
        } else if (c->argc == 4) {
            withvalues = 1;
            if (l < -LONG_MAX/2 || l > LONG_MAX/2) {
                addReplyError(c,"value is out of range");
                return;
            }
        }
        hrandfieldWithCountCommand(c, l, withvalues);
        return;
    }

    /* Handle variant without <count> argument. Reply with simple bulk string */
    if ((hash = lookupKeyReadOrReply(c,c->argv[1],shared.null[c->resp]))== NULL ||
        checkType(c,hash,OBJ_HASH)) {
        return;
    }

    hashTypeRandomElement(hash,hashTypeLength(hash, 0),&ele,NULL);
    hashReplyFromListpackEntry(c, &ele);
}

/*-----------------------------------------------------------------------------
 * Hash Field with optional expiry (based on mstr)
 *----------------------------------------------------------------------------*/
static hfield _hfieldNew(const void *field, size_t fieldlen, int withExpireMeta,
                         int trymalloc)
{
    if (!withExpireMeta)
        return mstrNew(field, fieldlen, trymalloc);

    hfield hf = mstrNewWithMeta(&mstrFieldKind, field, fieldlen,
                                (mstrFlags) 1 << HFIELD_META_EXPIRE, trymalloc);
    if (!hf) return NULL;

    ExpireMeta *expireMeta = mstrMetaRef(hf, &mstrFieldKind, HFIELD_META_EXPIRE);

    /* as long as it is not inside ebuckets, it is considered trash */
    expireMeta->trash = 1;
    return hf;
}

/* if expireAt is 0, then expireAt is ignored and no metadata is attached */
hfield hfieldNew(const void *field, size_t fieldlen, int withExpireMeta) {
    return _hfieldNew(field, fieldlen, withExpireMeta, 0);
}

hfield hfieldTryNew(const void *field, size_t fieldlen, int withExpireMeta) {
    return _hfieldNew(field, fieldlen, withExpireMeta, 1);
}

int hfieldIsExpireAttached(hfield field) {
    return mstrIsMetaAttached(field) && mstrGetFlag(field, (int) HFIELD_META_EXPIRE);
}

static ExpireMeta* hfieldGetExpireMeta(const eItem field) {
    /* extract the expireMeta from the field of type mstr */
    return mstrMetaRef(field, &mstrFieldKind, (int) HFIELD_META_EXPIRE);
}

/* returned value is unix time in milliseconds */
uint64_t hfieldGetExpireTime(hfield field) {
    if (!hfieldIsExpireAttached(field))
        return EB_EXPIRE_TIME_INVALID;

    ExpireMeta *expireMeta = mstrMetaRef(field, &mstrFieldKind, (int) HFIELD_META_EXPIRE);
    if (expireMeta->trash)
        return EB_EXPIRE_TIME_INVALID;

    return ebGetMetaExpTime(expireMeta);
}

/* Remove TTL from the field. Assumed ExpireMeta is attached and has valid value */
static void hfieldPersist(robj *hashObj, hfield field) {
    uint64_t fieldExpireTime = hfieldGetExpireTime(field);
    if (fieldExpireTime == EB_EXPIRE_TIME_INVALID)
        return;

    /* if field is set with expire, then dict must has HFE metadata attached */
    dict *d = hashObj->ptr;
    dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *)dictMetadata(d);

    /* If field has valid expiry then dict must have valid metadata as well */
    serverAssert(dictExpireMeta->expireMeta.trash == 0);

    /* Remove field from private HFE DS */
    ebRemove(&dictExpireMeta->hfe, &hashFieldExpireBucketsType, field);

    /* Don't have to update global HFE DS. It's unnecessary. Implementing this
     * would introduce significant complexity and overhead for an operation that
     * isn't critical. In the worst case scenario, the hash will be efficiently
     * updated later by an active-expire operation, or it will be removed by the
     * hash's dbGenericDelete() function. */
}

int hfieldIsExpired(hfield field) {
    /* Condition remains valid even if hfieldGetExpireTime() returns EB_EXPIRE_TIME_INVALID,
     * as the constant is equivalent to (EB_EXPIRE_TIME_MAX + 1). */
    return ( (mstime_t)hfieldGetExpireTime(field) < commandTimeSnapshot());
}

/*-----------------------------------------------------------------------------
 * Hash Field Expiration (HFE)
 *----------------------------------------------------------------------------*/
/*  Can be called either by active-expire cron job or query from the client */
static void propagateHashFieldDeletion(redisDb *db, sds key, char *field, size_t fieldLen) {
    robj *argv[] = {
        shared.hdel,
        createStringObject((char*) key, sdslen(key)),
        createStringObject(field, fieldLen)
    };

    enterExecutionUnit(1, 0);
    int prev_replication_allowed = server.replication_allowed;
    server.replication_allowed = 1;
    alsoPropagate(db->id,argv, 3, PROPAGATE_AOF|PROPAGATE_REPL);
    server.replication_allowed = prev_replication_allowed;
    exitExecutionUnit();

    /* Propagate the HDEL command */
    postExecutionUnitOperations();

    decrRefCount(argv[1]);
    decrRefCount(argv[2]);
}

/* Called during active expiration of hash-fields. Propagate to replica & Delete. */
static ExpireAction onFieldExpire(eItem item, void *ctx) {
    OnFieldExpireCtx *expCtx = ctx;
    hfield hf = item;
    dict *d = expCtx->hashObj->ptr;
    dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *) dictMetadata(d);
    propagateHashFieldDeletion(expCtx->db, dictExpireMeta->key, hf, hfieldlen(hf));
    serverAssert(hashTypeDelete(expCtx->hashObj, hf, 0) == 1);
    server.stat_expired_hash_fields++;
    return ACT_REMOVE_EXP_ITEM;
}

/* Retrieve the ExpireMeta associated with the hash.
 * The caller is responsible for ensuring that it is indeed attached. */
static ExpireMeta *hashGetExpireMeta(const eItem hash) {
    robj *hashObj = (robj *)hash;
    if (hashObj->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = hashObj->ptr;
        return &lpt->meta;
    } else if (hashObj->encoding == OBJ_ENCODING_HT) {
        dict *d = hashObj->ptr;
        dictExpireMetadata *dictExpireMeta = (dictExpireMetadata *) dictMetadata(d);
        return &dictExpireMeta->expireMeta;
    } else {
        serverPanic("Unknown encoding: %d", hashObj->encoding);
    }
}
/* HTTL key <FIELDS count field [field ...]>  */
static void httlGenericCommand(client *c, const char *cmd, long long basetime, int unit) {
    UNUSED(cmd);
    robj *hashObj;
    long numFields = 0, numFieldsAt = 3;

    /* Read the hash object */
    if ((hashObj = lookupKeyReadOrReply(c, c->argv[1], shared.emptyarray)) == NULL ||
        checkType(c, hashObj, OBJ_HASH)) return;

    if (strcasecmp(c->argv[numFieldsAt-1]->ptr, "FIELDS")) {
        addReplyError(c, "Mandatory argument FIELDS is missing or not at the right position");
        return;
    }

    /* Read number of fields */
    if (getRangeLongFromObjectOrReply(c, c->argv[numFieldsAt], 1, LONG_MAX,
                                      &numFields, "Number of fields must be a positive integer") != C_OK)
        return;

    /* Verify `numFields` is consistent with number of arguments */
    if (numFields > (c->argc - numFieldsAt - 1)) {
        addReplyError(c, "Parameter `numFileds` is more than number of arguments");
        return;
    }

    if (hashObj->encoding == OBJ_ENCODING_LISTPACK) {
        void *lp = hashObj->ptr;

        addReplyArrayLen(c, numFields);
        for (int i = 0 ; i < numFields ; i++) {
            sds field = c->argv[numFieldsAt+1+i]->ptr;
            void *fptr = lpFirst(lp);
            if (fptr != NULL)
                fptr = lpFind(lp, fptr, (unsigned char *) field, sdslen(field), 1);

            if (!fptr)
                addReplyLongLong(c, HFE_GET_NO_FIELD);
            else
                addReplyLongLong(c, HFE_GET_NO_TTL);
        }
        return;
    } else if (hashObj->encoding == OBJ_ENCODING_LISTPACK_EX) {
        listpackEx *lpt = hashObj->ptr;

        addReplyArrayLen(c, numFields);
        for (int i = 0 ; i < numFields ; i++) {
            long long expire;
            sds field = c->argv[numFieldsAt+1+i]->ptr;
            void *fptr = lpFirst(lpt->lp);
            if (fptr != NULL)
                fptr = lpFind(lpt->lp, fptr, (unsigned char *) field, sdslen(field), 2);

            if (!fptr) {
                addReplyLongLong(c, HFE_GET_NO_FIELD);
                continue;
            }

            fptr = lpNext(lpt->lp, fptr);
            serverAssert(fptr);
            fptr = lpNext(lpt->lp, fptr);
            serverAssert(fptr && lpGetIntegerValue(fptr, &expire));

            if (expire == HASH_LP_NO_TTL) {
                addReplyLongLong(c, HFE_GET_NO_TTL);
                continue;
            }

            if (expire <= commandTimeSnapshot()) {
                addReplyLongLong(c, HFE_GET_NO_FIELD);
                continue;
            }

            if (unit == UNIT_SECONDS)
                addReplyLongLong(c, (expire + 999 - basetime) / 1000);
            else
                addReplyLongLong(c, (expire - basetime));
        }
        return;
    } else if (hashObj->encoding == OBJ_ENCODING_HT) {
        dict *d = hashObj->ptr;

        addReplyArrayLen(c, numFields);
        for (int i = 0 ; i < numFields ; i++) {
            sds field = c->argv[numFieldsAt+1+i]->ptr;
            dictEntry *de = dictFind(d, field);
            if (de == NULL) {
                addReplyLongLong(c, HFE_GET_NO_FIELD);
                continue;
            }

            hfield hf = dictGetKey(de);
            uint64_t expire = hfieldGetExpireTime(hf);
            if (expire == EB_EXPIRE_TIME_INVALID) {
                addReplyLongLong(c, HFE_GET_NO_TTL); /* no ttl */
                continue;
            }

            if ( (long long) expire < commandTimeSnapshot()) {
                addReplyLongLong(c, HFE_GET_NO_FIELD);
                continue;
            }

            if (unit == UNIT_SECONDS)
                addReplyLongLong(c, (expire + 999 - basetime) / 1000);
            else
                addReplyLongLong(c, (expire - basetime));
        }
        return;
    } else {
        serverPanic("Unknown encoding: %d", hashObj->encoding);
    }
}

/* This is the generic command implementation for HEXPIRE, HPEXPIRE, HEXPIREAT
 * and HPEXPIREAT. Because the command second argument may be relative or absolute
 * the "basetime" argument is used to signal what the base time is (either 0
 * for *AT variants of the command, or the current time for relative expires).
 *
 * unit is either UNIT_SECONDS or UNIT_MILLISECONDS, and is only used for
 * the argv[2] parameter. The basetime is always specified in milliseconds.
 *
 * Additional flags are supported and parsed via parseExtendedExpireArguments */
static void hexpireGenericCommand(client *c, const char *cmd, long long basetime, int unit) {
    long numFields = 0, numFieldsAt = 4;
    long long expire; /* unix time in msec */
    int expireSetCond = 0;
    robj *hashObj, *keyArg = c->argv[1], *expireArg = c->argv[2];

    /* Read the hash object */
    if ((hashObj = lookupKeyWriteOrReply(c, keyArg, shared.emptyarray)) == NULL ||
        checkType(c, hashObj, OBJ_HASH)) return;

    /* Read the expiry time from command */
    if (getLongLongFromObjectOrReply(c, expireArg, &expire, NULL) != C_OK)
        return;

    /* Check expire overflow */
    if (expire > (long long) EB_EXPIRE_TIME_MAX) {
        addReplyErrorExpireTime(c);
        return;
    }

    if (unit == UNIT_SECONDS) {
        if (expire > (long long) EB_EXPIRE_TIME_MAX / 1000) {
            addReplyErrorExpireTime(c);
            return;
        }
        expire *= 1000;
    } else {
        if (expire > (long long) EB_EXPIRE_TIME_MAX) {
            addReplyErrorExpireTime(c);
            return;
        }
    }

    if (expire > (long long) EB_EXPIRE_TIME_MAX - basetime) {
        addReplyErrorExpireTime(c);
        return;
    }
    expire += basetime;

    /* Read optional expireSetCond [NX|XX|GT|LT] */
    char *optArg = c->argv[3]->ptr;
    if (!strcasecmp(optArg, "nx")) {
        expireSetCond = HFE_NX; ++numFieldsAt;
    } else if (!strcasecmp(optArg, "xx")) {
        expireSetCond = HFE_XX; ++numFieldsAt;
    } else if (!strcasecmp(optArg, "gt")) {
        expireSetCond = HFE_GT; ++numFieldsAt;
    } else if (!strcasecmp(optArg, "lt")) {
        expireSetCond = HFE_LT; ++numFieldsAt;
    }

    if (strcasecmp(c->argv[numFieldsAt-1]->ptr, "FIELDS")) {
        addReplyError(c, "Mandatory argument FIELDS is missing or not at the right position");
        return;
    }

    /* Read number of fields */
    if (getRangeLongFromObjectOrReply(c, c->argv[numFieldsAt], 1, LONG_MAX,
                                      &numFields, "Parameter `numFields` should be greater than 0") != C_OK)
        return;

    /* Verify `numFields` is consistent with number of arguments */
    if (numFields > (c->argc - numFieldsAt - 1)) {
        addReplyError(c, "Parameter `numFileds` is more than number of arguments");
        return;
    }

    HashTypeSetEx exCtx;
    hashTypeSetExInit(keyArg, hashObj, c, c->db, cmd,
                      FIELD_DONT_CREATE2,
                      expireSetCond,
                      &exCtx);

    addReplyArrayLen(c, numFields);

    for (int i = 0 ; i < numFields ; i++) {
        sds field = c->argv[numFieldsAt+i+1]->ptr;
        SetExRes res = hashTypeSetEx(c->db, hashObj, field, NULL, expire, &exCtx);
        addReplyLongLong(c,res);
    }
    hashTypeSetExDone(&exCtx);

    /* rewrite command for the replica sake */

    /* Propagate as HPEXPIREAT millisecond-timestamp. Rewrite only if not already */
    if (c->cmd->proc != hpexpireatCommand) {
        rewriteClientCommandArgument(c,0,shared.hpexpireat);
    }

    /* rewrite expiration time to unix time in msec  */
    if (basetime != 0 || unit == UNIT_SECONDS) {
        robj *expireObj = createStringObjectFromLongLong(expire);
        rewriteClientCommandArgument(c, 2, expireObj);
        decrRefCount(expireObj);
    }
}

/* HPEXPIRE key milliseconds [ NX | XX | GT | LT] numfields <field [field ...]> */
void hpexpireCommand(client *c) {
    hexpireGenericCommand(c,"hpexpire", commandTimeSnapshot(),UNIT_MILLISECONDS);
}

/* HEXPIRE key seconds [NX | XX | GT | LT] numfields <field [field ...]> */
void hexpireCommand(client *c) {
    hexpireGenericCommand(c,"hexpire", commandTimeSnapshot(),UNIT_SECONDS);
}

/* HEXPIREAT key unix-time-seconds [NX | XX | GT | LT] numfields <field [field ...]> */
void hexpireatCommand(client *c) {
    hexpireGenericCommand(c,"hexpireat", 0,UNIT_SECONDS);
}

/* HPEXPIREAT key unix-time-milliseconds [NX | XX | GT | LT] numfields <field [field ...]> */
void hpexpireatCommand(client *c) {
    hexpireGenericCommand(c,"hpexpireat", 0,UNIT_MILLISECONDS);
}

/* for each specified field: get the remaining time to live in seconds*/
/* HTTL key numfields <field [field ...]> */
void httlCommand(client *c) {
    httlGenericCommand(c, "httl", commandTimeSnapshot(), UNIT_SECONDS);
}

/* HPTTL key numfields <field [field ...]> */
void hpttlCommand(client *c) {
    httlGenericCommand(c, "hpttl", commandTimeSnapshot(), UNIT_MILLISECONDS);
}

/* HEXPIRETIME key numFields <field [field ...]> */
void hexpiretimeCommand(client *c) {
    httlGenericCommand(c, "hexpiretime", 0, UNIT_SECONDS);
}

/* HPEXPIRETIME key numFields <field [field ...]> */
void hpexpiretimeCommand(client *c) {
    httlGenericCommand(c, "hexpiretime", 0, UNIT_MILLISECONDS);
}

/* HPERSIST key <FIELDS count field [field ...]> */
void hpersistCommand(client *c) {
    robj *hashObj;
    long numFields = 0, numFieldsAt = 3;
    int changed = 0; /* Used to determine whether to send a notification. */

    /* Read the hash object */
    if ((hashObj = lookupKeyReadOrReply(c, c->argv[1], shared.emptyarray)) == NULL ||
        checkType(c, hashObj, OBJ_HASH)) return;

    if (strcasecmp(c->argv[numFieldsAt-1]->ptr, "FIELDS")) {
        addReplyError(c, "Mandatory argument FIELDS is missing or not at the right position");
        return;
    }

    /* Read number of fields */
    if (getRangeLongFromObjectOrReply(c, c->argv[numFieldsAt], 1, LONG_MAX,
                                      &numFields, "Number of fields must be a positive integer") != C_OK)
        return;

    /* Verify `numFields` is consistent with number of arguments */
    if (numFields > (c->argc - numFieldsAt - 1)) {
        addReplyError(c, "Parameter `numFileds` is more than number of arguments");
        return;
    }

    if (hashObj->encoding == OBJ_ENCODING_LISTPACK) {
        addReplyArrayLen(c, numFields);
        for (int i = 0 ; i < numFields ; i++) {
            sds field = c->argv[numFieldsAt + 1 + i]->ptr;
            unsigned char *fptr, *zl = hashObj->ptr;

            fptr = lpFirst(zl);
            if (fptr != NULL)
                fptr = lpFind(zl, fptr, (unsigned char *) field, sdslen(field), 1);

            if (!fptr)
                addReplyLongLong(c, HFE_PERSIST_NO_FIELD);
            else
                addReplyLongLong(c, HFE_PERSIST_NO_TTL);
        }
        return;
    } else if (hashObj->encoding == OBJ_ENCODING_LISTPACK_EX) {
        long long prevExpire;
        unsigned char *fptr, *vptr, *tptr;
        listpackEx *lpt = hashObj->ptr;

        addReplyArrayLen(c, numFields);
        for (int i = 0 ; i < numFields ; i++) {
            sds field = c->argv[numFieldsAt + 1 + i]->ptr;

            fptr = lpFirst(lpt->lp);
            if (fptr != NULL)
                fptr = lpFind(lpt->lp, fptr, (unsigned char*)field, sdslen(field), 2);

            if (!fptr) {
                addReplyLongLong(c, HFE_PERSIST_NO_FIELD);
                continue;
            }

            vptr = lpNext(lpt->lp, fptr);
            serverAssert(vptr);
            tptr = lpNext(lpt->lp, vptr);
            serverAssert(tptr && lpGetIntegerValue(tptr, &prevExpire));

            if (prevExpire == HASH_LP_NO_TTL) {
                addReplyLongLong(c, HFE_PERSIST_NO_TTL);
                continue;
            }

            if (prevExpire < commandTimeSnapshot()) {
                addReplyLongLong(c, HFE_PERSIST_NO_FIELD);
                continue;
            }

            listpackExUpdateExpiry(hashObj, field, fptr, vptr, HASH_LP_NO_TTL);
            addReplyLongLong(c, HFE_PERSIST_OK);
            changed = 1;
        }
    } else if (hashObj->encoding == OBJ_ENCODING_HT) {
        dict *d = hashObj->ptr;

        addReplyArrayLen(c, numFields);
        for (int i = 0 ; i < numFields ; i++) {
            sds field = c->argv[numFieldsAt + 1 + i]->ptr;
            dictEntry *de = dictFind(d, field);
            if (de == NULL) {
                addReplyLongLong(c, HFE_PERSIST_NO_FIELD);
                continue;
            }

            hfield hf = dictGetKey(de);
            uint64_t expire = hfieldGetExpireTime(hf);
            if (expire == EB_EXPIRE_TIME_INVALID) {
                addReplyLongLong(c, HFE_PERSIST_NO_TTL);
                continue;
            }

            /* Already expired. Pretend there is no such field */
            if ( (long long) expire < commandTimeSnapshot()) {
                addReplyLongLong(c, HFE_PERSIST_NO_FIELD);
                continue;
            }

            hfieldPersist(hashObj, hf);
            addReplyLongLong(c, HFE_PERSIST_OK);
            changed = 1;
        }
    } else {
        serverPanic("Unknown encoding: %d", hashObj->encoding);
    }

    /* Generates a hpersist event if the expiry time associated with any field
     * has been successfully deleted. */
    if (changed) notifyKeyspaceEvent(NOTIFY_HASH,"hpersist",c->argv[1],c->db->id);
}
