/* util.c -- vetores, matrizes e saturacoes */
#include <math.h>
#include <string.h>
#include "modelo.h"

double sat(double x, double l) { return x > l ? l : (x < -l ? -l : x); }
double lim(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }
double sgn(double x) { return x >= 0.0 ? 1.0 : -1.0; }

double wrap(double a)
{
    while (a > PI) a -= 2.0 * PI;
    while (a < -PI) a += 2.0 * PI;
    return a;
}

void cross(const double *a, const double *b, double *c)
{
    double t0 = a[1] * b[2] - a[2] * b[1];
    double t1 = a[2] * b[0] - a[0] * b[2];
    double t2 = a[0] * b[1] - a[1] * b[0];
    c[0] = t0; c[1] = t1; c[2] = t2;
}

double dot(const double *a, const double *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }

void mulR(double R[3][3], const double *v, double *o)
{
    double t[3];
    for (int i = 0; i < 3; i++) t[i] = R[i][0] * v[0] + R[i][1] * v[1] + R[i][2] * v[2];
    memcpy(o, t, sizeof t);
}

void mulRT(double R[3][3], const double *v, double *o)
{
    double t[3];
    for (int i = 0; i < 3; i++) t[i] = R[0][i] * v[0] + R[1][i] * v[1] + R[2][i] * v[2];
    memcpy(o, t, sizeof t);
}

/* matriz corpo -> NED a partir dos angulos de Euler do vetor de estados */
void rotacao(const double *x, double R[3][3])
{
    double cph = cos(x[XPHI]), sph = sin(x[XPHI]);
    double cth = cos(x[XTHE]), sth = sin(x[XTHE]);
    double cps = cos(x[XPSI]), sps = sin(x[XPSI]);
    R[0][0] = cth * cps; R[0][1] = sph * sth * cps - cph * sps; R[0][2] = cph * sth * cps + sph * sps;
    R[1][0] = cth * sps; R[1][1] = sph * sth * sps + cph * cps; R[1][2] = cph * sth * sps - sph * cps;
    R[2][0] = -sth;      R[2][1] = sph * cth;                   R[2][2] = cph * cth;
}

static double det3(double A[3][3])
{
    return A[0][0] * (A[1][1] * A[2][2] - A[1][2] * A[2][1])
         - A[0][1] * (A[1][0] * A[2][2] - A[1][2] * A[2][0])
         + A[0][2] * (A[1][0] * A[2][1] - A[1][1] * A[2][0]);
}

/* resolve A x = b (3x3) por Cramer */
void resolve3(double A[3][3], const double *b, double *x)
{
    double d = det3(A);
    for (int k = 0; k < 3; k++) {
        double M[3][3];
        memcpy(M, A, sizeof M);
        for (int i = 0; i < 3; i++) M[i][k] = b[i];
        x[k] = det3(M) / d;
    }
}

/* mistura linear / placa plana (Beard e McLain): 0 antes do estol, 1 depois */
double sigma_estol(double al, double a0, double M)
{
    double e1 = exp(-M * (al - a0)), e2 = exp(M * (al + a0));
    return (1.0 + e1 + e2) / ((1.0 + e1) * (1.0 + e2));
}
