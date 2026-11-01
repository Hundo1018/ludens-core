"""Complex FFT, radix 2, iterative (ROADMAP 17.60: the ocean spectrum's
height field is one inverse 2-D transform per update).

Split real / imaginary lists rather than a complex type, like the rest of
`numerics`. `fft(re, im, inverse)` transforms in place; the inverse divides
by n, so `fft(fft(x), inverse=True)` is x up to rounding. `fft2` does rows
then columns of a row-major n x n array. Lengths must be powers of two
(raises otherwise: an engine-level size is a caller's choice, checked once).
"""

from std.math import pi
from geometry.trig import sin, cos
from geometry.vec import Real


def is_pow2(n: Int) -> Bool:
    return n > 0 and (n & (n - 1)) == 0


def fft(mut re: List[Real], mut im: List[Real], inverse: Bool = False) raises:
    var n = len(re)
    if len(im) != n or not is_pow2(n):
        raise Error("fft: re and im must have the same power-of-two length")
    # bit reversal
    var j = 0
    for i in range(1, n):
        var bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            var tr = re[i]
            re[i] = re[j]
            re[j] = tr
            var ti = im[i]
            im[i] = im[j]
            im[j] = ti
    var sign = Real(1) if inverse else Real(-1)
    var len_ = 2
    while len_ <= n:
        var ang = sign * 2 * Real(pi) / Real(len_)
        var wr = cos(ang)
        var wi = sin(ang)
        var half = len_ >> 1
        var start = 0
        while start < n:
            var cr = Real(1)
            var ci = Real(0)
            for k in range(half):
                var a = start + k
                var b = a + half
                var xr = re[b] * cr - im[b] * ci
                var xi = re[b] * ci + im[b] * cr
                re[b] = re[a] - xr
                im[b] = im[a] - xi
                re[a] = re[a] + xr
                im[a] = im[a] + xi
                var nr = cr * wr - ci * wi
                ci = cr * wi + ci * wr
                cr = nr
            start += len_
        len_ <<= 1
    if inverse:
        var s = 1 / Real(n)
        for i in range(n):
            re[i] *= s
            im[i] *= s


def fft2(mut re: List[Real], mut im: List[Real], n: Int, inverse: Bool = False) raises:
    """Row-major n x n transform: every row, then every column."""
    if len(re) != n * n or len(im) != n * n:
        raise Error("fft2: arrays must hold n * n values")
    var rr = List[Real](length=n, fill=0)
    var ri = List[Real](length=n, fill=0)
    for r in range(n):
        for c in range(n):
            rr[c] = re[r * n + c]
            ri[c] = im[r * n + c]
        fft(rr, ri, inverse)
        for c in range(n):
            re[r * n + c] = rr[c]
            im[r * n + c] = ri[c]
    for c in range(n):
        for r in range(n):
            rr[r] = re[r * n + c]
            ri[r] = im[r * n + c]
        fft(rr, ri, inverse)
        for r in range(n):
            re[r * n + c] = rr[r]
            im[r * n + c] = ri[r]
