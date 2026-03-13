#include <stdio.h>
#include <string.h>
#include <math.h>
#include <sys/time.h>
#include "fast_float_strtod.h"

/* Benchmark: fast_float_strtod parsing "2.5441141205676571e-01" */
static int fastFloatBenchTest() {
    // const char *str = "2.545676571e-01";
    // const char *str = "2.5456";
    // const char *str = "2.1e1";
    // const char *str = "2.54411412076571e-011";
    // const char *str = "-inf";
    const char *str = "+inf";
    size_t len = strlen(str);
    const double expected = 0.254205676571;
    // const double expected = 0.254205676571;
    int iterations = 1;
    // int iterations = 1000000000;
    struct timeval start, end;
    double sum = 0;

    gettimeofday(&start, NULL);
    for (int i = 0; i < iterations; i++) {
        char *eptr;
        // sum += fast_float_strtod(str, &eptr);
        sum += fast_float_strtod(str, len, &eptr);
        // printf("%f\n", sum);
    }
    gettimeofday(&end, NULL);

    double elapsed = (end.tv_sec - start.tv_sec) + (end.tv_usec - start.tv_usec) / 1e6;
    double per_call_ns = (elapsed * 1e9) / iterations;
    double result = fast_float_strtod(str, len, NULL);

    printf("fast_float_strtod benchmark (\"%s\"):\n", str);
    printf("  iterations: %d, elapsed: %.3f s\n", iterations, elapsed);
    printf("  %.2f ns/call, %.1f M calls/s\n", per_call_ns, 1000.0 / per_call_ns);
    printf("  result: %.17g (expected %.17g) %s\n", result, expected,
           fabs(result - expected) < 1e-15 ? "[OK]" : "[MISMATCH]");
    (void)sum;
    return 0;
}

int main() {
    fastFloatBenchTest();
    return 0;
}