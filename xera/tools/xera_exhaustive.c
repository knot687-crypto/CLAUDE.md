/* xera_exhaustive.c - scans all 1,073,741,824 XERA curves with the script's exact integer
 * arithmetic. C division truncates toward zero like GPC, and every intermediate fits in int32;
 * int64 is used here only for headroom.
 *
 *   xera_exhaustive t th Lhat Sstar W2 W3 pr0 pr1 pr2 pr3   -> "minJ argmin_id ties"
 *   xera_exhaustive props                                   -> monotonicity / end-point check of
 *                                                              all 16,777,216 base curves
 *
 * xera_maps.h (lattice maps and weights) is generated from xera_model.py by verify_xera.py,
 * which also builds this file:  gcc -O3 -fopenmp -I<dir> xera_exhaustive.c */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xera_maps.h"

typedef int64_t i64;
static inline i64 idiv(i64 a, i64 b) { return a / b; }

typedef struct { i64 p, A, iK, q, R, iR, den; int flat, lo; } curve;

static inline void prep(curve *c, int ip, int ia, int ik, int ir) {
    c->p = P_MAP[ip]; c->A = A_MAP[ia]; c->iK = IK_MAP[ik]; c->R = R_MAP[ir]; c->iR = IR_MAP[ir];
    i64 K = K_MAP[ik];
    c->q = idiv(K * c->p, idiv(c->A * (4096 - c->p) + K * c->p, 4096));
}

static inline i64 level(curve *c, i64 t) {
    if (t >= c->R) { c->flat = 1; return 4096; }
    c->flat = 0;
    i64 tr = idiv(t * c->iR, 4096);
    if (tr < c->p) {
        i64 u = idiv(tr * 4096, c->p);
        c->den = idiv((c->A - 4096) * (4096 - u), 4096) + 4096; c->lo = 1;
        return idiv(c->q * u, c->den);
    }
    i64 w = idiv((tr - c->p) * 4096, 4096 - c->p);
    c->den = idiv((c->iK - 4096) * (4096 - w), 4096) + 4096; c->lo = 0;
    return c->q + idiv((4096 - c->q) * w, c->den);
}

static inline i64 slope14(curve *c) {          /* gain in Q14 at the t of the last level() */
    if (c->flat) return 0;
    i64 g;
    if (c->lo) g = idiv(idiv(c->q * 16384, c->p) * c->A, c->den);
    else g = idiv(idiv((4096 - c->q) * 16384, 4096 - c->p) * c->iK, c->den);
    return idiv(idiv(g * 4096, c->den) * c->iR, 4096);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "props")) {
        long bad_mono = 0, bad_end = 0;
        #pragma omp parallel for reduction(+:bad_mono, bad_end) schedule(dynamic)
        for (int ik = 0; ik < 256; ik++)
            for (int ia = 0; ia < 256; ia++)
                for (int ip = 0; ip < 256; ip++) {
                    curve c;
                    prep(&c, ip, ia, ik, 63);                    /* reach 1.00 = the base curve */
                    i64 prev = -1;
                    for (i64 t = 0; t <= 4096; t += 4) {
                        i64 f = level(&c, t);
                        if ((t == 0 && f != 0) || (t == 4096 && f != 4096)) bad_end++;
                        if (f < prev) bad_mono++;
                        prev = f;
                    }
                }
        printf("%ld %ld\n", bad_mono, bad_end);
        return 0;
    }
    if (argc != 11) { fprintf(stderr, "usage: xera_exhaustive t th Lhat Sstar W2 W3 pr0 pr1 pr2 pr3 | props\n"); return 2; }
    i64 t = atoll(argv[1]), th = atoll(argv[2]), Lhat = atoll(argv[3]), S = atoll(argv[4]);
    i64 W2 = atoll(argv[5]), W3 = atoll(argv[6]);
    i64 pr0 = atoll(argv[7]), pr1 = atoll(argv[8]), pr2 = atoll(argv[9]), pr3 = atoll(argv[10]);
    i64 gmin = INT64_MAX, gid = -1;
    long ties = 0;
    #pragma omp parallel
    {
        i64 lmin = INT64_MAX, lid = -1;
        long lties = 0;
        #pragma omp for schedule(dynamic)
        for (int ik = 0; ik < 256; ik++)
            for (int ia = 0; ia < 256; ia++)
                for (int ip = 0; ip < 256; ip++) {
                    curve c;
                    prep(&c, ip, ia, ik, 0);
                    i64 e = 2 * ip - pr0, base = W4 * e * e;
                    e = 2 * ia - pr1; base += W4 * e * e;
                    e = 2 * ik - pr2; base += W4 * e * e;
                    for (int ir = 0; ir < 64; ir++) {
                        c.R = R_MAP[ir]; c.iR = IR_MAP[ir];
                        i64 J = 0, d;
                        level(&c, t);
                        if (W2 > 0) { d = idiv(slope14(&c) - 4 * S, 16); J = W2 * d * d; }
                        if (W3 > 0) { d = idiv(level(&c, th) - Lhat, 4); J += W3 * d * d; }
                        e = 2 * ir - pr3;
                        J += base + W4R * e * e;
                        if (J < lmin) { lmin = J; lid = ip | (ia << 8) | (ik << 16) | ((i64)ir << 24); lties = 1; }
                        else if (J == lmin) lties++;
                    }
                }
        #pragma omp critical
        {
            if (lmin < gmin) { gmin = lmin; gid = lid; ties = lties; }
            else if (lmin == gmin) ties += lties;
        }
    }
    printf("%lld %lld %ld\n", (long long)gmin, (long long)gid, ties);
    return 0;
}
