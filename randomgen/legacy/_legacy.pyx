#!python
#cython: wraparound=False, nonecheck=False, boundscheck=False, cdivision=True, language_level=3
from __future__ import absolute_import

import warnings
import operator

from cpython.pycapsule cimport PyCapsule_IsValid, PyCapsule_GetPointer
from libc.stdlib cimport malloc, free
cimport numpy as np
import numpy as np
cimport cython

try:
    from threading import Lock
except ImportError:
    from dummy_threading import Lock

from randomgen.bounded_integers cimport *
from randomgen.bounded_integers import _randint_types
from randomgen.common cimport cont, disc, double_fill, CONS_NONE, \
    CONS_POSITIVE, CONS_NON_NEGATIVE, CONS_BOUNDED_0_1
from randomgen.distributions cimport brng_t, random_double_fill
from randomgen.legacy.legacy_distributions cimport *
from randomgen.xoroshiro128 import Xoroshiro128
import randomgen.pickle

np.import_array()


cdef class _LegacyGenerator:
    """
    _LegacyGenerator(brng=None)

    Container providing legacy generators.

    ``_LegacyGenerator`` exposes a number of methods for generating random
    numbers for a set of distributions where the method used to produce random
    samples has changed. Three core generators have changed: normal, exponential
    and gamma. These have been replaced by faster Ziggurat-based methods in
    ``RandomGenerator``. ``_LegacyGenerator`` retains the slower methods
    to produce samples from these distributions as well as from distributions
    that depend on these such as the Chi-square, power or Weibull.

    **No Compatibility Guarantee**

    ``_LegacyGenerator`` is evolving and so it isn't possible to provide a
    compatibility guarantee like NumPy does. In particular, better algorithms
    have already been added. This will change once ``RandomGenerator``
    stabilizes.

    Parameters
    ----------
    brng : Basic RNG, optional
        Basic RNG to use as the core generator. If none is provided, uses
        Xoroshiro128.

    Examples
    --------
    Exactly reproducing a NumPy stream requires both a ``RandomGenerator``
    and a ``_LegacyGenerator``.  These must share a common ``MT19937`` basic
    RNG. Functions that are available in LegacyGenerator must be called
    from ``_LegacyGenerator``, and other functions must be called from
    ``RandomGenerator``.

    >>> from randomgen import RandomGenerator, MT19937
    >>> from randomgen.legacy._legacy import _LegacyGenerator
    >>> mt = MT19937(12345)
    >>> lg = _LegacyGenerator(mt)
    >>> rg = RandomGenerator(mt)
    >>> x = lg.standard_normal(10)
    >>> rg.shuffle(x)
    >>> x[0]
    0.09290787674371767
    >>> lg.standard_exponential()
    1.6465621229906502

    The equivalent commands from NumPy produce identical output.

    >>> from numpy.random import RandomState
    >>> rs = RandomState(12345)
    >>> x = rs.standard_normal(10)
    >>> rs.shuffle(x)
    >>> x[0]
    0.09290787674371767
    >>> rs.standard_exponential()
    1.6465621229906502
    """
    cdef public object _basicrng
    cdef brng_t *_brng
    cdef aug_brng_t *_aug_state
    cdef object lock

    def __init__(self, brng=None):
        if brng is None:
            brng = Xoroshiro128()
        self._basicrng = brng

        capsule = brng.capsule
        cdef const char *name = "BasicRNG"
        if not PyCapsule_IsValid(capsule, name):
            raise ValueError("Invalid brng. The brng must be instantized.")
        self._brng = <brng_t *> PyCapsule_GetPointer(capsule, name)
        self._aug_state = <aug_brng_t *>malloc(sizeof(aug_brng_t))
        self._aug_state.basicrng = self._brng
        self._reset_gauss()
        self.lock = Lock()

    def __dealloc__(self):
        free(self._aug_state)

    def __repr__(self):
        return self.__str__() + ' at 0x{:X}'.format(id(self))

    def __str__(self):
        return self.__class__.__name__ + '(' + self._basicrng.__class__.__name__ + ')'

    # Pickling support:
    def __getstate__(self):
        return self.state

    def __setstate__(self, state):
        self.state = state

    def __reduce__(self):
        return (randomgen.pickle.__legacy_ctor,
                (self.state['brng'],),
                self.state)

    cdef _reset_gauss(self):
        self._aug_state.has_gauss = 0
        self._aug_state.gauss = 0.0

    def seed(self, *args, **kwargs):
        """
        Reseed the basic RNG.

        Parameters depend on the basic RNG used.

        Notes
        -----
        Arguments are directly passed to the basic RNG. This is a convenience
        function.

        The best method to access seed is to directly use a basic RNG instance.
        This example demonstrates this best practice.

        >>> from randomgen import MT19937
        >>> from randomgen.legacy import LegacyGenerator
        >>> brng = MT19937(123456789)
        >>> lg = brng.generator
        >>> brng.seed(987654321)

        The method used to create the generator is not important.

        >>> brng = MT19937(123456789)
        >>> lg = LegacyGenerator(brng)
        >>> brng.seed(987654321)

        These best practice examples are equivalent to

        >>> lg = LegacyGenerator(MT19937(123456789))
        >>> lg.seed(987654321)
        """

        # TODO: Should this remain
        self._basicrng.seed(*args, **kwargs)
        self._reset_gauss()
        return self

    @property
    def state(self):
        """
        Get or set the augmented state

        Returns the basic RNGs state as well as two values added to track
        normal generation using the Polar (Box-Muller-like) method.

        Returns
        -------
        state : dict
            Dictionary containing the information required to describe the
            state of the Basic RNG with two additional fields, gauss and
            has_gauss, required to store generated Polar transformation
            (Box-Muller-like) normals.
        """
        st = self._basicrng.state
        st['has_gauss'] = self._aug_state.has_gauss
        st['gauss'] = self._aug_state.gauss
        return st

    @state.setter
    def state(self, value):
        if isinstance(value, tuple):
            if value[0] != 'MT19937':
                raise ValueError('tuple only supported for MT19937')
            st = {'brng': value[0],
                  'state': {'key': value[1], 'pos': value[2]}}
            if len(value) > 3:
                st['has_gauss'] = value[3]
                st['gauss'] = value[4]
            value = st
        self._aug_state.gauss = value.get('gauss', 0.0)
        self._aug_state.has_gauss = value.get('has_gauss', 0)
        self._basicrng.state = value

    def get_state(self):
        """
        get_state()

        Return a tuple representing the internal state of the generator.

        For more details, see `set_state`.

        Returns
        -------
        out : tuple(str, ndarray of 624 uints, int, int, float)
            The returned tuple has the following items:

            1. the string 'MT19937'.
            2. a 1-D array of 624 unsigned integer keys.
            3. an integer ``pos``.
            4. an integer ``has_gauss``.
            5. a float ``cached_gaussian``.

        See Also
        --------
        set_state

        Notes
        -----
        `set_state` and `get_state` are not needed to work with any of the
        random distributions in NumPy. If the internal state is manually altered,
        the user should know exactly what he/she is doing.
        """
        st = self._basicrng.state
        if st['brng'] != 'MT19937':
            raise RuntimeError('get_state can only be used with the MT19937 '
                               'basic RNG. When using other basic RNGs, '
                               'use `state`.')
        st['has_gauss'] = self._aug_state.has_gauss
        st['gauss'] = self._aug_state.gauss

        return (st['brng'], st['state']['key'], st['state']['pos'],
                st['has_gauss'], st['gauss'])

    def set_state(self, state):
        """
        set_state(state)

        Set the internal state of the generator from a tuple.

        For use if one has reason to manually (re-)set the internal state of the
        "Mersenne Twister"[1]_ pseudo-random number generating algorithm.

        Parameters
        ----------
        state : tuple(str, ndarray of 624 uints, int, int, float)
            The `state` tuple has the following items:

            1. the string 'MT19937', specifying the Mersenne Twister algorithm.
            2. a 1-D array of 624 unsigned integers ``keys``.
            3. an integer ``pos``.
            4. an integer ``has_gauss``.
            5. a float ``cached_gaussian``.

        Returns
        -------
        out : None
            Returns 'None' on success.

        See Also
        --------
        get_state

        Notes
        -----
        `set_state` and `get_state` are not needed to work with any of the
        random distributions in NumPy. If the internal state is manually altered,
        the user should know exactly what he/she is doing.

        For backwards compatibility, the form (str, array of 624 uints, int) is
        also accepted although it is missing some information about the cached
        Gaussian value: ``state = ('MT19937', keys, pos)``.

        References
        ----------
        .. [1] M. Matsumoto and T. Nishimura, "Mersenne Twister: A
           623-dimensionally equidistributed uniform pseudorandom number
           generator," *ACM Trans. on Modeling and Computer Simulation*,
           Vol. 8, No. 1, pp. 3-30, Jan. 1998.
        """
        if not isinstance(state, (tuple, list)):
            raise TypeError('state must be a tuple when using set_state.  '
                             'Use `state` to set the state using a dictionary.')
        if state[0] != 'MT19937':
            raise ValueError('set_state can only be used with legacy MT19937'
                             'state instances.')
        st = {'brng': state[0],
              'state': {'key': state[1], 'pos': state[2]}}
        if len(state) > 3:
            st['has_gauss'] = state[3]
            st['gauss'] = state[4]
            value = st
        self._aug_state.gauss = value.get('gauss', 0.0)
        self._aug_state.has_gauss = value.get('has_gauss', 0)
        self._basicrng.state = value

    def random_sample(self, size=None):
        """
        random_sample(size=None)

        Return random floats in the half-open interval [0.0, 1.0).

        Results are from the "continuous uniform" distribution over the
        stated interval.  To sample :math:`Unif[a, b), b > a` multiply
        the output of `random_sample` by `(b-a)` and add `a`::

          (b - a) * random_sample() + a

        Parameters
        ----------
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.

        Returns
        -------
        out : float or ndarray of floats
            Array of random floats of shape `size` (unless ``size=None``, in which
            case a single float is returned).

        Examples
        --------
        np.random.random_sample()
        0.47108547995356098
        type(np.random.random_sample())
        <type 'float'>
        np.random.random_sample((5,))
        array([ 0.30220482,  0.86820401,  0.1654503 ,  0.11659149,  0.54323428])

        Three-by-two array of random numbers from [-5, 0):

        5 * np.random.random_sample((3, 2)) - 5
        array([[-3.99149989, -0.52338984],
               [-2.99091858, -0.79479508],
               [-1.23204345, -1.75224494]])
        """
        cdef double temp
        return double_fill(&random_double_fill, self._brng, size, self.lock, None)

    def beta(self, a, b, size=None):
        """
        beta(a, b, size=None)

        Draw samples from a Beta distribution.

        The Beta distribution is a special case of the Dirichlet distribution,
        and is related to the Gamma distribution.  It has the probability
        distribution function

        .. math:: f(x; a,b) = \\frac{1}{B(\\alpha, \\beta)} x^{\\alpha - 1}
                                                         (1 - x)^{\\beta - 1},

        where the normalization, B, is the beta function,

        .. math:: B(\\alpha, \\beta) = \\int_0^1 t^{\\alpha - 1}
                                     (1 - t)^{\\beta - 1} dt.

        It is often seen in Bayesian inference and order statistics.

        Parameters
        ----------
        a : float or array_like of floats
            Alpha, positive (>0).
        b : float or array_like of floats
            Beta, positive (>0).
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``a`` and ``b`` are both scalars.
            Otherwise, ``np.broadcast(a, b).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized beta distribution.

        """
        return cont(&legacy_beta, self._aug_state, size, self.lock, 2,
                    a, 'a', CONS_POSITIVE,
                    b, 'b', CONS_POSITIVE,
                    0.0, '', CONS_NONE, None)

    def exponential(self, scale=1.0, size=None):
        """
        exponential(scale=1.0, size=None)

        Draw samples from an exponential distribution.

        Its probability density function is

        .. math:: f(x; \\frac{1}{\\beta}) = \\frac{1}{\\beta} \\exp(-\\frac{x}{\\beta}),

        for ``x > 0`` and 0 elsewhere. :math:`\\beta` is the scale parameter,
        which is the inverse of the rate parameter :math:`\\lambda = 1/\\beta`.
        The rate parameter is an alternative, widely used parameterization
        of the exponential distribution [3]_.

        The exponential distribution is a continuous analogue of the
        geometric distribution.  It describes many common situations, such as
        the size of raindrops measured over many rainstorms [1]_, or the time
        between page requests to Wikipedia [2]_.

        Parameters
        ----------
        scale : float or array_like of floats
            The scale parameter, :math:`\\beta = 1/\\lambda`.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``scale`` is a scalar.  Otherwise,
            ``np.array(scale).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized exponential distribution.

        References
        ----------
        .. [1] Peyton Z. Peebles Jr., "Probability, Random Variables and
               Random Signal Principles", 4th ed, 2001, p. 57.
        .. [2] Wikipedia, "Poisson process",
               https://en.wikipedia.org/wiki/Poisson_process
        .. [3] Wikipedia, "Exponential distribution",
               https://en.wikipedia.org/wiki/Exponential_distribution

        """
        return cont(&legacy_exponential, self._aug_state, size, self.lock, 1,
                    scale, 'scale', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE,
                    0.0, '', CONS_NONE,
                    None)

    def standard_exponential(self, size=None):
        """
        standard_exponential(size=None)

        Draw samples from the standard exponential distribution.

        `standard_exponential` is identical to the exponential distribution
        with a scale parameter of 1.

        Parameters
        ----------
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.

        Returns
        -------
        out : float or ndarray
            Drawn samples.

        Examples
        --------
        Output a 3x8000 array:

        >>> n = randomgen.generator.standard_exponential((3, 8000))
        """
        return cont(&legacy_standard_exponential, self._aug_state, size, self.lock, 0,
                    None, None, CONS_NONE,
                    None, None, CONS_NONE,
                    None, None, CONS_NONE,
                    None)

    def randint(self, low, high=None, size=None, dtype=int):
        """
        randint(low, high=None, size=None, dtype='l')

        Return random integers from `low` (inclusive) to `high` (exclusive).

        Return random integers from the "discrete uniform" distribution of
        the specified dtype in the "half-open" interval [`low`, `high`). If
        `high` is None (the default), then results are from [0, `low`).

        Parameters
        ----------
        low : int or array-like of ints
            Lowest (signed) integers to be drawn from the distribution (unless
            ``high=None``, in which case this parameter is one above the
            *highest* such integer).
        high : int or array-like of ints, optional
            If provided, one above the largest (signed) integer to be drawn
            from the distribution (see above for behavior if ``high=None``).
            If array-like, must contain integer values
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.
        dtype : {str, dtype}, optional
            Desired dtype of the result. All dtypes are determined by their
            name, i.e., 'int64', 'int', etc, so byteorder is not available
            and a specific precision may have different C types depending
            on the platform. The default value is 'np.int'.

            .. versionadded:: 1.11.0

        Returns
        -------
        out : int or ndarray of ints
            `size`-shaped array of random integers from the appropriate
            distribution, or a single such random int if `size` not provided.

        See Also
        --------
        random.random_integers : similar to `randint`, only for the closed
            interval [`low`, `high`], and 1 is the lowest value if `high` is
            omitted. In particular, this other one is the one to use to generate
            uniformly distributed discrete non-integers.

        Examples
        --------
        >>> randomgen.generator.randint(2, size=10)
        array([1, 0, 0, 0, 1, 1, 0, 0, 1, 0]) # random
        >>> randomgen.generator.randint(1, size=10)
        array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) # random

        Generate a 2 x 4 array of ints between 0 and 4, inclusive:

        >>> randomgen.generator.randint(5, size=(2, 4))
        array([[4, 0, 2, 1], # random
               [3, 2, 2, 0]])

        Generate a 1 x 3 array with 3 different upper bounds

        >>> randomgen.generator.randint(1, [3, 5, 10])
        array([2, 2, 9]) # random

        Generate a 1 by 3 array with 3 different lower bounds

        >>> randomgen.generator.randint([1, 5, 7], 10)
        array([9, 8, 7]) # random

        Generate a 2 by 4 array using broadcasting with dtype of uint8

        >>> randomgen.generator.randint([1, 3, 5, 7], [[10], [20]], dtype=np.uint8)
        array([[ 8,  6,  9,  7], # random
               [ 1, 16,  9, 12]], dtype=uint8)
        """
        cdef bint use_masked=1

        if high is None:
            high = low
            low = 0

        key = np.dtype(dtype).name
        if not key in _randint_types:
            raise TypeError('Unsupported dtype "%s" for randint' % key)

        if key == 'int32':
            ret =  _rand_int32(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'int64':
            ret =  _rand_int64(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'int16':
            ret =  _rand_int16(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'int8':
            ret =  _rand_int8(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'uint64':
            ret =  _rand_uint64(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'uint32':
            ret =  _rand_uint32(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'uint16':
            ret =  _rand_uint16(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'uint8':
            ret =  _rand_uint8(low, high, size, use_masked, self._brng, self.lock)
        elif key == 'bool':
            ret =  _rand_bool(low, high, size, use_masked, self._brng, self.lock)

        if size is None and dtype in (np.bool, np.int, np.long):
                if np.array(ret).shape == ():
                    return dtype(ret)
        return ret

    def rand(self, *args):
        """
        rand(d0, d1, ..., dn)

        Random values in a given shape.

        Create an array of the given shape and populate it with
        random samples from a uniform distribution
        over ``[0, 1)``.

        Parameters
        ----------
        d0, d1, ..., dn : int, optional
            The dimensions of the returned array, should all be positive.
            If no argument is given a single Python float is returned.

        Returns
        -------
        out : ndarray, shape ``(d0, d1, ..., dn)``
            Random values.

        See Also
        --------
        random

        Notes
        -----
        This is a convenience function. If you want an interface that
        takes a shape-tuple as the first argument, refer to
        np.random.random_sample .

        Examples
        --------
        >>> np.random.rand(3,2)
        array([[ 0.14022471,  0.96360618],  #random
               [ 0.37601032,  0.25528411],  #random
               [ 0.49313049,  0.94909878]]) #random
        """
        if len(args) == 0:
            return self.random_sample()
        else:
            return self.random_sample(size=args)

    def randn(self, *args):
        """
        randn(d0, d1, ..., dn)

        Return a sample (or samples) from the "standard normal" distribution.

        If positive, int_like or int-convertible arguments are provided,
        `randn` generates an array of shape ``(d0, d1, ..., dn)``, filled
        with random floats sampled from a univariate "normal" (Gaussian)
        distribution of mean 0 and variance 1 (if any of the :math:`d_i` are
        floats, they are first converted to integers by truncation). A single
        float randomly sampled from the distribution is returned if no
        argument is provided.

        This is a convenience function.  If you want an interface that takes a
        tuple as the first argument, use `standard_normal` instead.

        Parameters
        ----------
        d0, d1, ..., dn : int, optional
            The dimensions of the returned array, should be all positive.
            If no argument is given a single Python float is returned.

        Returns
        -------
        Z : ndarray or float
            A ``(d0, d1, ..., dn)``-shaped array of floating-point samples from
            the standard normal distribution, or a single such float if
            no parameters were supplied.

        See Also
        --------
        standard_normal : Similar, but takes a tuple as its argument.

        Notes
        -----
        For random samples from :math:`N(\\mu, \\sigma^2)`, use:

        ``sigma * randomgen.generator.randn(...) + mu``

        Examples
        --------
        >>> randomgen.generator.randn()
        2.1923875335537315 #random

        Two-by-four array of samples from N(3, 6.25):

        >>> 2.5 * randomgen.generator.randn(2, 4) + 3
        array([[-4.49401501,  4.00950034, -1.81814867,  7.29718677],  #random
               [ 0.39924804,  4.68456316,  4.99394529,  4.84057254]]) #random

        """
        if len(args) == 0:
            return self.standard_normal()
        else:
            return self.standard_normal(size=args)

    # Complicated, continuous distributions:
    def standard_normal(self, size=None):
        """
        standard_normal(size=None)

        Draw samples from a standard Normal distribution (mean=0, stdev=1).

        Parameters
        ----------
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.

        Returns
        -------
        out : float or ndarray
            Drawn samples.

        Examples
        --------
        >>> s = randomgen.generator.standard_normal(8000)
        >>> s
        array([ 0.6888893 ,  0.78096262, -0.89086505, ...,  0.49876311, #random
               -0.38672696, -0.4685006 ])                               #random
        >>> s.shape
        (8000,)
        >>> s = randomgen.generator.standard_normal(size=(3, 4, 2))
        >>> s.shape
        (3, 4, 2)

        """
        return cont(&legacy_gauss, self._aug_state, size, self.lock, 0,
                    None, None, CONS_NONE,
                    None, None, CONS_NONE,
                    None, None, CONS_NONE,
                    None)

    def normal(self, loc=0.0, scale=1.0, size=None):
        """
        normal(loc=0.0, scale=1.0, size=None)

        Draw random samples from a normal (Gaussian) distribution.

        The probability density function of the normal distribution, first
        derived by De Moivre and 200 years later by both Gauss and Laplace
        independently [2]_, is often called the bell curve because of
        its characteristic shape (see the example below).

        The normal distributions occurs often in nature.  For example, it
        describes the commonly occurring distribution of samples influenced
        by a large number of tiny, random disturbances, each with its own
        unique distribution [2]_.

        Parameters
        ----------
        loc : float or array_like of floats
            Mean ("centre") of the distribution.
        scale : float or array_like of floats
            Standard deviation (spread or "width") of the distribution.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``loc`` and ``scale`` are both scalars.
            Otherwise, ``np.broadcast(loc, scale).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized normal distribution.

        See Also
        --------
        scipy.stats.norm : probability density function, distribution or
            cumulative density function, etc.

        Notes
        -----
        The probability density for the Gaussian distribution is

        .. math:: p(x) = \\frac{1}{\\sqrt{ 2 \\pi \\sigma^2 }}
                         e^{ - \\frac{ (x - \\mu)^2 } {2 \\sigma^2} },

        where :math:`\\mu` is the mean and :math:`\\sigma` the standard
        deviation. The square of the standard deviation, :math:`\\sigma^2`,
        is called the variance.

        The function has its peak at the mean, and its "spread" increases with
        the standard deviation (the function reaches 0.607 times its maximum at
        :math:`x + \\sigma` and :math:`x - \\sigma` [2]_).  This implies that
        `numpy.random.normal` is more likely to return samples lying close to
        the mean, rather than those far away.

        References
        ----------
        .. [1] Wikipedia, "Normal distribution",
               https://en.wikipedia.org/wiki/Normal_distribution
        .. [2] P. R. Peebles Jr., "Central Limit Theorem" in "Probability,
               Random Variables and Random Signal Principles", 4th ed., 2001,
               pp. 51, 51, 125.

        Examples
        --------
        Draw samples from the distribution:

        >>> mu, sigma = 0, 0.1 # mean and standard deviation
        >>> s = randomgen.generator.normal(mu, sigma, 1000)

        Verify the mean and the variance:

        >>> abs(mu - np.mean(s)) < 0.01
        True

        >>> abs(sigma - np.std(s, ddof=1)) < 0.01
        True

        Display the histogram of the samples, along with
        the probability density function:

        >>> import matplotlib.pyplot as plt
        >>> count, bins, ignored = plt.hist(s, 30, density=True)
        >>> plt.plot(bins, 1/(sigma * np.sqrt(2 * np.pi)) *
        ...                np.exp( - (bins - mu)**2 / (2 * sigma**2) ),
        ...          linewidth=2, color='r')
        >>> plt.show()

        """
        return cont(&legacy_normal, self._aug_state, size, self.lock, 2,
                    loc, '', CONS_NONE,
                    scale, 'scale', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE,
                    None)

    def standard_gamma(self, shape, size=None):
        """
        standard_gamma(shape, size=None)

        Draw samples from a standard Gamma distribution.

        Samples are drawn from a Gamma distribution with specified parameters,
        shape (sometimes designated "k") and scale=1.

        Parameters
        ----------
        shape : float or array_like of floats
            Parameter, should be > 0.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``shape`` is a scalar.  Otherwise,
            ``np.array(shape).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized standard gamma distribution.

        See Also
        --------
        scipy.stats.gamma : probability density function, distribution or
            cumulative density function, etc.

        Notes
        -----
        The probability density for the Gamma distribution is

        .. math:: p(x) = x^{k-1}\\frac{e^{-x/\\theta}}{\\theta^k\\Gamma(k)},

        where :math:`k` is the shape and :math:`\\theta` the scale,
        and :math:`\\Gamma` is the Gamma function.

        The Gamma distribution is often used to model the times to failure of
        electronic components, and arises naturally in processes for which the
        waiting times between Poisson distributed events are relevant.

        References
        ----------
        .. [1] Weisstein, Eric W. "Gamma Distribution." From MathWorld--A
               Wolfram Web Resource.
               http://mathworld.wolfram.com/GammaDistribution.html
        .. [2] Wikipedia, "Gamma distribution",
               https://en.wikipedia.org/wiki/Gamma_distribution

        Examples
        --------
        Draw samples from the distribution:

        >>> shape, scale = 2., 1. # mean and width
        >>> s = randomgen.generator.standard_gamma(shape, 1000000)

        Display the histogram of the samples, along with
        the probability density function:

        >>> import matplotlib.pyplot as plt
        >>> import scipy.special as sps
        >>> count, bins, ignored = plt.hist(s, 50, density=True)
        >>> y = bins**(shape-1) * ((np.exp(-bins/scale))/ \\
        ...                       (sps.gamma(shape) * scale**shape))
        >>> plt.plot(bins, y, linewidth=2, color='r')
        >>> plt.show()
        """
        return cont(&legacy_standard_gamma, self._aug_state, size, self.lock, 1,
                    shape, 'shape', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE,
                    0.0, '', CONS_NONE,
                    None)

    def gamma(self, shape, scale=1.0, size=None):
        """
        gamma(shape, scale=1.0, size=None)

        Draw samples from a Gamma distribution.

        Samples are drawn from a Gamma distribution with specified parameters,
        `shape` (sometimes designated "k") and `scale` (sometimes designated
        "theta"), where both parameters are > 0.

        Parameters
        ----------
        shape : float or array_like of floats
            The shape of the gamma distribution. Should be greater than zero.
        scale : float or array_like of floats, optional
            The scale of the gamma distribution. Should be greater than zero.
            Default is equal to 1.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``shape`` and ``scale`` are both scalars.
            Otherwise, ``np.broadcast(shape, scale).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized gamma distribution.

        See Also
        --------
        scipy.stats.gamma : probability density function, distribution or
            cumulative density function, etc.

        Notes
        -----
        The probability density for the Gamma distribution is

        .. math:: p(x) = x^{k-1}\\frac{e^{-x/\\theta}}{\\theta^k\\Gamma(k)},

        where :math:`k` is the shape and :math:`\\theta` the scale,
        and :math:`\\Gamma` is the Gamma function.

        The Gamma distribution is often used to model the times to failure of
        electronic components, and arises naturally in processes for which the
        waiting times between Poisson distributed events are relevant.

        References
        ----------
        .. [1] Weisstein, Eric W. "Gamma Distribution." From MathWorld--A
               Wolfram Web Resource.
               http://mathworld.wolfram.com/GammaDistribution.html
        .. [2] Wikipedia, "Gamma distribution",
               https://en.wikipedia.org/wiki/Gamma_distribution

        Examples
        --------
        Draw samples from the distribution:

        >>> shape, scale = 2., 2. # mean and dispersion
        >>> s = randomgen.generator.gamma(shape, scale, 1000)

        Display the histogram of the samples, along with
        the probability density function:

        >>> import matplotlib.pyplot as plt
        >>> import scipy.special as sps
        >>> count, bins, ignored = plt.hist(s, 50, density=True)
        >>> y = bins**(shape-1)*(np.exp(-bins/scale) /
        ...                      (sps.gamma(shape)*scale**shape))
        >>> plt.plot(bins, y, linewidth=2, color='r')
        >>> plt.show()

        """
        return cont(&legacy_gamma, self._aug_state, size, self.lock, 2,
                    shape, 'shape', CONS_NON_NEGATIVE,
                    scale, 'scale', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE, None)

    def f(self, dfnum, dfden, size=None):
        """
        f(dfnum, dfden, size=None)

        Draw samples from an F distribution.

        Samples are drawn from an F distribution with specified parameters,
        `dfnum` (degrees of freedom in numerator) and `dfden` (degrees of
        freedom in denominator), where both parameters should be greater than
        zero.

        The random variate of the F distribution (also known as the
        Fisher distribution) is a continuous probability distribution
        that arises in ANOVA tests, and is the ratio of two chi-square
        variates.

        Parameters
        ----------
        dfnum : int or array_like of ints
            Degrees of freedom in numerator. Should be greater than zero.
        dfden : int or array_like of ints
            Degrees of freedom in denominator. Should be greater than zero.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``dfnum`` and ``dfden`` are both scalars.
            Otherwise, ``np.broadcast(dfnum, dfden).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized Fisher distribution.

        See Also
        --------
        scipy.stats.f : probability density function, distribution or
            cumulative density function, etc.

        Notes
        -----
        The F statistic is used to compare in-group variances to between-group
        variances. Calculating the distribution depends on the sampling, and
        so it is a function of the respective degrees of freedom in the
        problem.  The variable `dfnum` is the number of samples minus one, the
        between-groups degrees of freedom, while `dfden` is the within-groups
        degrees of freedom, the sum of the number of samples in each group
        minus the number of groups.

        References
        ----------
        .. [1] Glantz, Stanton A. "Primer of Biostatistics.", McGraw-Hill,
               Fifth Edition, 2002.
        .. [2] Wikipedia, "F-distribution",
               https://en.wikipedia.org/wiki/F-distribution

        Examples
        --------
        An example from Glantz[1], pp 47-40:

        Two groups, children of diabetics (25 people) and children from people
        without diabetes (25 controls). Fasting blood glucose was measured,
        case group had a mean value of 86.1, controls had a mean value of
        82.2. Standard deviations were 2.09 and 2.49 respectively. Are these
        data consistent with the null hypothesis that the parents diabetic
        status does not affect their children's blood glucose levels?
        Calculating the F statistic from the data gives a value of 36.01.

        Draw samples from the distribution:

        >>> dfnum = 1. # between group degrees of freedom
        >>> dfden = 48. # within groups degrees of freedom
        >>> s = randomgen.generator.f(dfnum, dfden, 1000)

        The lower bound for the top 1% of the samples is :

        >>> np.sort(s)[-10]
        7.61988120985 # random

        So there is about a 1% chance that the F statistic will exceed 7.62,
        the measured value is 36, so the null hypothesis is rejected at the 1%
        level.

        """
        return cont(&legacy_f, self._aug_state, size, self.lock, 2,
                    dfnum, 'dfnum', CONS_POSITIVE,
                    dfden, 'dfden', CONS_POSITIVE,
                    0.0, '', CONS_NONE, None)

    def noncentral_f(self, dfnum, dfden, nonc, size=None):
        """
        noncentral_f(dfnum, dfden, nonc, size=None)

        Draw samples from the noncentral F distribution.

        Samples are drawn from an F distribution with specified parameters,
        `dfnum` (degrees of freedom in numerator) and `dfden` (degrees of
        freedom in denominator), where both parameters > 1.
        `nonc` is the non-centrality parameter.

        Parameters
        ----------
        dfnum : int or array_like of ints
            Parameter, should be > 1.
        dfden : int or array_like of ints
            Parameter, should be > 1.
        nonc : float or array_like of floats
            Parameter, should be >= 0.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``dfnum``, ``dfden``, and ``nonc``
            are all scalars.  Otherwise, ``np.broadcast(dfnum, dfden, nonc).size``
            samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized noncentral Fisher distribution.

        Notes
        -----
        When calculating the power of an experiment (power = probability of
        rejecting the null hypothesis when a specific alternative is true) the
        non-central F statistic becomes important.  When the null hypothesis is
        true, the F statistic follows a central F distribution. When the null
        hypothesis is not true, then it follows a non-central F statistic.

        References
        ----------
        .. [1] Weisstein, Eric W. "Noncentral F-Distribution."
               From MathWorld--A Wolfram Web Resource.
               http://mathworld.wolfram.com/NoncentralF-Distribution.html
        .. [2] Wikipedia, "Noncentral F-distribution",
               https://en.wikipedia.org/wiki/Noncentral_F-distribution

        Examples
        --------
        In a study, testing for a specific alternative to the null hypothesis
        requires use of the Noncentral F distribution. We need to calculate the
        area in the tail of the distribution that exceeds the value of the F
        distribution for the null hypothesis.  We'll plot the two probability
        distributions for comparison.

        >>> dfnum = 3 # between group deg of freedom
        >>> dfden = 20 # within groups degrees of freedom
        >>> nonc = 3.0
        >>> nc_vals = randomgen.generator.noncentral_f(dfnum, dfden, nonc, 1000000)
        >>> NF = np.histogram(nc_vals, bins=50, density=True)
        >>> c_vals = randomgen.generator.f(dfnum, dfden, 1000000)
        >>> F = np.histogram(c_vals, bins=50, density=True)
        >>> import matplotlib.pyplot as plt
        >>> plt.plot(F[1][1:], F[0])
        >>> plt.plot(NF[1][1:], NF[0])
        >>> plt.show()

        """
        return cont(&legacy_noncentral_f, self._aug_state, size, self.lock, 3,
                    dfnum, 'dfnum', CONS_POSITIVE,
                    dfden, 'dfden', CONS_POSITIVE,
                    nonc, 'nonc', CONS_NON_NEGATIVE, None)

    def chisquare(self, df, size=None):
        """
        chisquare(df, size=None)

        Draw samples from a chi-square distribution.

        When `df` independent random variables, each with standard normal
        distributions (mean 0, variance 1), are squared and summed, the
        resulting distribution is chi-square (see Notes).  This distribution
        is often used in hypothesis testing.

        Parameters
        ----------
        df : int or array_like of ints
             Number of degrees of freedom.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``df`` is a scalar.  Otherwise,
            ``np.array(df).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized chi-square distribution.

        Raises
        ------
        ValueError
            When `df` <= 0 or when an inappropriate `size` (e.g. ``size=-1``)
            is given.

        Notes
        -----
        The variable obtained by summing the squares of `df` independent,
        standard normally distributed random variables:

        .. math:: Q = \\sum_{i=0}^{\\mathtt{df}} X^2_i

        is chi-square distributed, denoted

        .. math:: Q \\sim \\chi^2_k.

        The probability density function of the chi-squared distribution is

        .. math:: p(x) = \\frac{(1/2)^{k/2}}{\\Gamma(k/2)}
                         x^{k/2 - 1} e^{-x/2},

        where :math:`\\Gamma` is the gamma function,

        .. math:: \\Gamma(x) = \\int_0^{-\\infty} t^{x - 1} e^{-t} dt.

        References
        ----------
        .. [1] NIST "Engineering Statistics Handbook"
               https://www.itl.nist.gov/div898/handbook/eda/section3/eda3666.htm

        Examples
        --------
        >>> randomgen.generator.chisquare(2,4)
        array([ 1.89920014,  9.00867716,  3.13710533,  5.62318272]) # random

        """
        return cont(&legacy_chisquare, self._aug_state, size, self.lock, 1,
                    df, 'df', CONS_POSITIVE,
                    0.0, '', CONS_NONE,
                    0.0, '', CONS_NONE, None)

    def noncentral_chisquare(self, df, nonc, size=None):
        """
        noncentral_chisquare(df, nonc, size=None)

        Draw samples from a noncentral chi-square distribution.

        The noncentral :math:`\\chi^2` distribution is a generalisation of
        the :math:`\\chi^2` distribution.

        Parameters
        ----------
        df : int or array_like of ints
            Degrees of freedom, should be > 0 as of NumPy 1.10.0,
            should be > 1 for earlier versions.
        nonc : float or array_like of floats
            Non-centrality, should be non-negative.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``df`` and ``nonc`` are both scalars.
            Otherwise, ``np.broadcast(df, nonc).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized noncentral chi-square distribution.

        Notes
        -----
        The probability density function for the noncentral Chi-square
        distribution is

        .. math:: P(x;df,nonc) = \\sum^{\\infty}_{i=0}
                               \\frac{e^{-nonc/2}(nonc/2)^{i}}{i!}
                               \\P_{Y_{df+2i}}(x),

        where :math:`Y_{q}` is the Chi-square with q degrees of freedom.

        References
        ----------
        .. [1] Wikipedia, "Noncentral chi-square distribution"
               https://en.wikipedia.org/wiki/Noncentral_chi-square_distribution

        Examples
        --------
        Draw values from the distribution and plot the histogram

        >>> import matplotlib.pyplot as plt
        >>> values = plt.hist(randomgen.generator.noncentral_chisquare(3, 20, 100000),
        ...                   bins=200, density=True)
        >>> plt.show()

        Draw values from a noncentral chisquare with very small noncentrality,
        and compare to a chisquare.

        >>> plt.figure()
        >>> values = plt.hist(randomgen.generator.noncentral_chisquare(3, .0000001, 100000),
        ...                   bins=np.arange(0., 25, .1), density=True)
        >>> values2 = plt.hist(randomgen.generator.chisquare(3, 100000),
        ...                    bins=np.arange(0., 25, .1), density=True)
        >>> plt.plot(values[1][0:-1], values[0]-values2[0], 'ob')
        >>> plt.show()

        Demonstrate how large values of non-centrality lead to a more symmetric
        distribution.

        >>> plt.figure()
        >>> values = plt.hist(randomgen.generator.noncentral_chisquare(3, 20, 100000),
        ...                   bins=200, density=True)
        >>> plt.show()

        """
        return cont(&legacy_noncentral_chisquare, self._aug_state, size, self.lock, 2,
                    df, 'df', CONS_POSITIVE,
                    nonc, 'nonc', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE, None)

    def standard_cauchy(self, size=None):
        """
        standard_cauchy(size=None)

        Draw samples from a standard Cauchy distribution with mode = 0.

        Also known as the Lorentz distribution.

        Parameters
        ----------
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.

        Returns
        -------
        samples : ndarray or scalar
            The drawn samples.

        Notes
        -----
        The probability density function for the full Cauchy distribution is

        .. math:: P(x; x_0, \\gamma) = \\frac{1}{\\pi \\gamma \\bigl[ 1+
                  (\\frac{x-x_0}{\\gamma})^2 \\bigr] }

        and the Standard Cauchy distribution just sets :math:`x_0=0` and
        :math:`\\gamma=1`

        The Cauchy distribution arises in the solution to the driven harmonic
        oscillator problem, and also describes spectral line broadening. It
        also describes the distribution of values at which a line tilted at
        a random angle will cut the x axis.

        When studying hypothesis tests that assume normality, seeing how the
        tests perform on data from a Cauchy distribution is a good indicator of
        their sensitivity to a heavy-tailed distribution, since the Cauchy looks
        very much like a Gaussian distribution, but with heavier tails.

        References
        ----------
        .. [1] NIST/SEMATECH e-Handbook of Statistical Methods, "Cauchy
              Distribution",
              http://www.itl.nist.gov/div898/handbook/eda/section3/eda3663.htm
        .. [2] Weisstein, Eric W. "Cauchy Distribution." From MathWorld--A
              Wolfram Web Resource.
              http://mathworld.wolfram.com/CauchyDistribution.html
        .. [3] Wikipedia, "Cauchy distribution"
              https://en.wikipedia.org/wiki/Cauchy_distribution

        Examples
        --------
        Draw samples and plot the distribution:

        >>> s = randomgen.generator.standard_cauchy(1000000)
        >>> s = s[(s>-25) & (s<25)]  # truncate distribution so it plots well
        >>> import matplotlib.pyplot as plt
        >>> plt.hist(s, bins=100)
        >>> plt.show()

        """
        return cont(&legacy_standard_cauchy, self._aug_state, size, self.lock, 0,
                    0.0, '', CONS_NONE, 0.0, '', CONS_NONE, 0.0, '', CONS_NONE, None)

    def standard_t(self, df, size=None):
        """
        standard_t(df, size=None)

        Draw samples from a standard Student's t distribution with `df` degrees
        of freedom.

        A special case of the hyperbolic distribution.  As `df` gets
        large, the result resembles that of the standard normal
        distribution (`standard_normal`).

        Parameters
        ----------
        df : int or array_like of ints
            Degrees of freedom, should be > 0.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``df`` is a scalar.  Otherwise,
            ``np.array(df).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized standard Student's t distribution.

        Notes
        -----
        The probability density function for the t distribution is

        .. math:: P(x, df) = \\frac{\\Gamma(\\frac{df+1}{2})}{\\sqrt{\\pi df}
                  \\Gamma(\\frac{df}{2})}\\Bigl( 1+\\frac{x^2}{df} \\Bigr)^{-(df+1)/2}

        The t test is based on an assumption that the data come from a
        Normal distribution. The t test provides a way to test whether
        the sample mean (that is the mean calculated from the data) is
        a good estimate of the true mean.

        The derivation of the t-distribution was first published in
        1908 by William Gosset while working for the Guinness Brewery
        in Dublin. Due to proprietary issues, he had to publish under
        a pseudonym, and so he used the name Student.

        References
        ----------
        .. [1] Dalgaard, Peter, "Introductory Statistics With R",
               Springer, 2002.
        .. [2] Wikipedia, "Student's t-distribution"
               https://en.wikipedia.org/wiki/Student's_t-distribution

        Examples
        --------
        From Dalgaard page 83 [1]_, suppose the daily energy intake for 11
        women in kilojoules (kJ) is:

        >>> intake = np.array([5260., 5470, 5640, 6180, 6390, 6515, 6805, 7515, \\
        ...                    7515, 8230, 8770])

        Does their energy intake deviate systematically from the recommended
        value of 7725 kJ?

        We have 10 degrees of freedom, so is the sample mean within 95% of the
        recommended value?

        >>> s = randomgen.generator.standard_t(10, size=100000)
        >>> np.mean(intake)
        6753.636363636364
        >>> intake.std(ddof=1)
        1142.1232221373727

        Calculate the t statistic, setting the ddof parameter to the unbiased
        value so the divisor in the standard deviation will be degrees of
        freedom, N-1.

        >>> t = (np.mean(intake)-7725)/(intake.std(ddof=1)/np.sqrt(len(intake)))
        >>> import matplotlib.pyplot as plt
        >>> h = plt.hist(s, bins=100, density=True)

        For a one-sided t-test, how far out in the distribution does the t
        statistic appear?

        >>> np.sum(s<t) / float(len(s))
        0.0090699999999999999  #random

        So the p-value is about 0.009, which says the null hypothesis has a
        probability of about 99% of being true.

        """
        return cont(&legacy_standard_t, self._aug_state, size, self.lock, 1,
                    df, 'df', CONS_POSITIVE,
                    0, '', CONS_NONE,
                    0, '', CONS_NONE,
                    None)

    def pareto(self, a, size=None):
        """
        pareto(a, size=None)

        Draw samples from a Pareto II or Lomax distribution with
        specified shape.

        The Lomax or Pareto II distribution is a shifted Pareto
        distribution. The classical Pareto distribution can be
        obtained from the Lomax distribution by adding 1 and
        multiplying by the scale parameter ``m`` (see Notes).  The
        smallest value of the Lomax distribution is zero while for the
        classical Pareto distribution it is ``mu``, where the standard
        Pareto distribution has location ``mu = 1``.  Lomax can also
        be considered as a simplified version of the Generalized
        Pareto distribution (available in SciPy), with the scale set
        to one and the location set to zero.

        The Pareto distribution must be greater than zero, and is
        unbounded above.  It is also known as the "80-20 rule".  In
        this distribution, 80 percent of the weights are in the lowest
        20 percent of the range, while the other 20 percent fill the
        remaining 80 percent of the range.

        Parameters
        ----------
        a : float or array_like of floats
            Shape of the distribution. Should be greater than zero.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``a`` is a scalar.  Otherwise,
            ``np.array(a).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized Pareto distribution.

        See Also
        --------
        scipy.stats.lomax : probability density function, distribution or
            cumulative density function, etc.
        scipy.stats.genpareto : probability density function, distribution or
            cumulative density function, etc.

        Notes
        -----
        The probability density for the Pareto distribution is

        .. math:: p(x) = \\frac{am^a}{x^{a+1}}

        where :math:`a` is the shape and :math:`m` the scale.

        The Pareto distribution, named after the Italian economist
        Vilfredo Pareto, is a power law probability distribution
        useful in many real world problems.  Outside the field of
        economics it is generally referred to as the Bradford
        distribution. Pareto developed the distribution to describe
        the distribution of wealth in an economy.  It has also found
        use in insurance, web page access statistics, oil field sizes,
        and many other problems, including the download frequency for
        projects in Sourceforge [1]_.  It is one of the so-called
        "fat-tailed" distributions.


        References
        ----------
        .. [1] Francis Hunt and Paul Johnson, On the Pareto Distribution of
               Sourceforge projects.
        .. [2] Pareto, V. (1896). Course of Political Economy. Lausanne.
        .. [3] Reiss, R.D., Thomas, M.(2001), Statistical Analysis of Extreme
               Values, Birkhauser Verlag, Basel, pp 23-30.
        .. [4] Wikipedia, "Pareto distribution",
               https://en.wikipedia.org/wiki/Pareto_distribution

        Examples
        --------
        Draw samples from the distribution:

        >>> a, m = 3., 2.  # shape and mode
        >>> s = (randomgen.generator.pareto(a, 1000) + 1) * m

        Display the histogram of the samples, along with the probability
        density function:

        >>> import matplotlib.pyplot as plt
        >>> count, bins, _ = plt.hist(s, 100, density=True)
        >>> fit = a*m**a / bins**(a+1)
        >>> plt.plot(bins, max(count)*fit/max(fit), linewidth=2, color='r')
        >>> plt.show()

        """
        return cont(&legacy_pareto, self._aug_state, size, self.lock, 1,
                    a, 'a', CONS_POSITIVE,
                    0.0, '', CONS_NONE,
                    0.0, '', CONS_NONE, None)

    def weibull(self, a, size=None):
        """
        weibull(a, size=None)

        Draw samples from a Weibull distribution.

        Draw samples from a 1-parameter Weibull distribution with the given
        shape parameter `a`.

        .. math:: X = (-ln(U))^{1/a}

        Here, U is drawn from the uniform distribution over (0,1].

        The more common 2-parameter Weibull, including a scale parameter
        :math:`\\lambda` is just :math:`X = \\lambda(-ln(U))^{1/a}`.

        Parameters
        ----------
        a : float or array_like of floats
            Shape parameter of the distribution.  Must be nonnegative.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``a`` is a scalar.  Otherwise,
            ``np.array(a).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized Weibull distribution.

        See Also
        --------
        scipy.stats.weibull_max
        scipy.stats.weibull_min
        scipy.stats.genextreme
        gumbel

        Notes
        -----
        The Weibull (or Type III asymptotic extreme value distribution
        for smallest values, SEV Type III, or Rosin-Rammler
        distribution) is one of a class of Generalized Extreme Value
        (GEV) distributions used in modeling extreme value problems.
        This class includes the Gumbel and Frechet distributions.

        The probability density for the Weibull distribution is

        .. math:: p(x) = \\frac{a}
                         {\\lambda}(\\frac{x}{\\lambda})^{a-1}e^{-(x/\\lambda)^a},

        where :math:`a` is the shape and :math:`\\lambda` the scale.

        The function has its peak (the mode) at
        :math:`\\lambda(\\frac{a-1}{a})^{1/a}`.

        When ``a = 1``, the Weibull distribution reduces to the exponential
        distribution.

        References
        ----------
        .. [1] Waloddi Weibull, Royal Technical University, Stockholm,
               1939 "A Statistical Theory Of The Strength Of Materials",
               Ingeniorsvetenskapsakademiens Handlingar Nr 151, 1939,
               Generalstabens Litografiska Anstalts Forlag, Stockholm.
        .. [2] Waloddi Weibull, "A Statistical Distribution Function of
               Wide Applicability", Journal Of Applied Mechanics ASME Paper
               1951.
        .. [3] Wikipedia, "Weibull distribution",
               https://en.wikipedia.org/wiki/Weibull_distribution

        Examples
        --------
        Draw samples from the distribution:

        >>> a = 5. # shape
        >>> s = randomgen.generator.weibull(a, 1000)

        Display the histogram of the samples, along with
        the probability density function:

        >>> import matplotlib.pyplot as plt
        >>> x = np.arange(1,100.)/50.
        >>> def weib(x,n,a):
        ...     return (a / n) * (x / n)**(a - 1) * np.exp(-(x / n)**a)

        >>> count, bins, ignored = plt.hist(randomgen.generator.weibull(5.,1000))
        >>> x = np.arange(1,100.)/50.
        >>> scale = count.max()/weib(x, 1., 5.).max()
        >>> plt.plot(x, weib(x, 1., 5.)*scale)
        >>> plt.show()

        """
        return cont(&legacy_weibull, self._aug_state, size, self.lock, 1,
                    a, 'a', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE,
                    0.0, '', CONS_NONE, None)

    def power(self, a, size=None):
        """
        power(a, size=None)

        Draws samples in [0, 1] from a power distribution with positive
        exponent a - 1.

        Also known as the power function distribution.

        Parameters
        ----------
        a : float or array_like of floats
            Parameter of the distribution. Should be greater than zero.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``a`` is a scalar.  Otherwise,
            ``np.array(a).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized power distribution.

        Raises
        ------
        ValueError
            If a < 1.

        Notes
        -----
        The probability density function is

        .. math:: P(x; a) = ax^{a-1}, 0 \\le x \\le 1, a>0.

        The power function distribution is just the inverse of the Pareto
        distribution. It may also be seen as a special case of the Beta
        distribution.

        It is used, for example, in modeling the over-reporting of insurance
        claims.

        References
        ----------
        .. [1] Christian Kleiber, Samuel Kotz, "Statistical size distributions
               in economics and actuarial sciences", Wiley, 2003.
        .. [2] Heckert, N. A. and Filliben, James J. "NIST Handbook 148:
               Dataplot Reference Manual, Volume 2: Let Subcommands and Library
               Functions", National Institute of Standards and Technology
               Handbook Series, June 2003.
               http://www.itl.nist.gov/div898/software/dataplot/refman2/auxillar/powpdf.pdf

        Examples
        --------
        Draw samples from the distribution:

        >>> a = 5. # shape
        >>> samples = 1000
        >>> s = randomgen.generator.power(a, samples)

        Display the histogram of the samples, along with
        the probability density function:

        >>> import matplotlib.pyplot as plt
        >>> count, bins, ignored = plt.hist(s, bins=30)
        >>> x = np.linspace(0, 1, 100)
        >>> y = a*x**(a-1.)
        >>> normed_y = samples*np.diff(bins)[0]*y
        >>> plt.plot(x, normed_y)
        >>> plt.show()

        Compare the power function distribution to the inverse of the Pareto.

        >>> from scipy import stats
        >>> rvs = randomgen.generator.power(5, 1000000)
        >>> rvsp = randomgen.generator.pareto(5, 1000000)
        >>> xx = np.linspace(0,1,100)
        >>> powpdf = stats.powerlaw.pdf(xx,5)

        >>> plt.figure()
        >>> plt.hist(rvs, bins=50, density=True)
        >>> plt.plot(xx,powpdf,'r-')
        >>> plt.title('randomgen.generator.power(5)')

        >>> plt.figure()
        >>> plt.hist(1./(1.+rvsp), bins=50, density=True)
        >>> plt.plot(xx,powpdf,'r-')
        >>> plt.title('inverse of 1 + randomgen.generator.pareto(5)')

        >>> plt.figure()
        >>> plt.hist(1./(1.+rvsp), bins=50, density=True)
        >>> plt.plot(xx,powpdf,'r-')
        >>> plt.title('inverse of stats.pareto(5)')

        """
        return cont(&legacy_power, self._aug_state, size, self.lock, 1,
                    a, 'a', CONS_POSITIVE,
                    0.0, '', CONS_NONE,
                    0.0, '', CONS_NONE, None)

    def lognormal(self, mean=0.0, sigma=1.0, size=None):
        """
        lognormal(mean=0.0, sigma=1.0, size=None)

        Draw samples from a log-normal distribution.

        Draw samples from a log-normal distribution with specified mean,
        standard deviation, and array shape.  Note that the mean and standard
        deviation are not the values for the distribution itself, but of the
        underlying normal distribution it is derived from.

        Parameters
        ----------
        mean : float or array_like of floats, optional
            Mean value of the underlying normal distribution. Default is 0.
        sigma : float or array_like of floats, optional
            Standard deviation of the underlying normal distribution. Should
            be greater than zero. Default is 1.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``mean`` and ``sigma`` are both scalars.
            Otherwise, ``np.broadcast(mean, sigma).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized log-normal distribution.

        See Also
        --------
        scipy.stats.lognorm : probability density function, distribution,
            cumulative density function, etc.

        Notes
        -----
        A variable `x` has a log-normal distribution if `log(x)` is normally
        distributed.  The probability density function for the log-normal
        distribution is:

        .. math:: p(x) = \\frac{1}{\\sigma x \\sqrt{2\\pi}}
                         e^{(-\\frac{(ln(x)-\\mu)^2}{2\\sigma^2})}

        where :math:`\\mu` is the mean and :math:`\\sigma` is the standard
        deviation of the normally distributed logarithm of the variable.
        A log-normal distribution results if a random variable is the *product*
        of a large number of independent, identically-distributed variables in
        the same way that a normal distribution results if the variable is the
        *sum* of a large number of independent, identically-distributed
        variables.

        References
        ----------
        .. [1] Limpert, E., Stahel, W. A., and Abbt, M., "Log-normal
               Distributions across the Sciences: Keys and Clues,"
               BioScience, Vol. 51, No. 5, May, 2001.
               https://stat.ethz.ch/~stahel/lognormal/bioscience.pdf
        .. [2] Reiss, R.D. and Thomas, M., "Statistical Analysis of Extreme
               Values," Basel: Birkhauser Verlag, 2001, pp. 31-32.

        Examples
        --------
        Draw samples from the distribution:

        >>> mu, sigma = 3., 1. # mean and standard deviation
        >>> s = randomgen.generator.lognormal(mu, sigma, 1000)

        Display the histogram of the samples, along with
        the probability density function:

        >>> import matplotlib.pyplot as plt
        >>> count, bins, ignored = plt.hist(s, 100, density=True, align='mid')

        >>> x = np.linspace(min(bins), max(bins), 10000)
        >>> pdf = (np.exp(-(np.log(x) - mu)**2 / (2 * sigma**2))
        ...        / (x * sigma * np.sqrt(2 * np.pi)))

        >>> plt.plot(x, pdf, linewidth=2, color='r')
        >>> plt.axis('tight')
        >>> plt.show()

        Demonstrate that taking the products of random samples from a uniform
        distribution can be fit well by a log-normal probability density
        function.

        >>> # Generate a thousand samples: each is the product of 100 random
        >>> # values, drawn from a normal distribution.
        >>> b = []
        >>> for i in range(1000):
        ...    a = 10. + randomgen.generator.randn(100)
        ...    b.append(np.product(a))

        >>> b = np.array(b) / np.min(b) # scale values to be positive
        >>> count, bins, ignored = plt.hist(b, 100, density=True, align='mid')
        >>> sigma = np.std(np.log(b))
        >>> mu = np.mean(np.log(b))

        >>> x = np.linspace(min(bins), max(bins), 10000)
        >>> pdf = (np.exp(-(np.log(x) - mu)**2 / (2 * sigma**2))
        ...        / (x * sigma * np.sqrt(2 * np.pi)))

        >>> plt.plot(x, pdf, color='r', linewidth=2)
        >>> plt.show()

        """
        return cont(&legacy_lognormal, self._aug_state, size, self.lock, 2,
                    mean, 'mean', CONS_NONE,
                    sigma, 'sigma', CONS_NON_NEGATIVE,
                    0.0, '', CONS_NONE, None)

    def wald(self, mean, scale, size=None):
        """
        wald(mean, scale, size=None)

        Draw samples from a Wald, or inverse Gaussian, distribution.

        As the scale approaches infinity, the distribution becomes more like a
        Gaussian. Some references claim that the Wald is an inverse Gaussian
        with mean equal to 1, but this is by no means universal.

        The inverse Gaussian distribution was first studied in relationship to
        Brownian motion. In 1956 M.C.K. Tweedie used the name inverse Gaussian
        because there is an inverse relationship between the time to cover a
        unit distance and distance covered in unit time.

        Parameters
        ----------
        mean : float or array_like of floats
            Distribution mean, must be > 0.
        scale : float or array_like of floats
            Scale parameter, must be > 0.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``mean`` and ``scale`` are both scalars.
            Otherwise, ``np.broadcast(mean, scale).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized Wald distribution.

        Notes
        -----
        The probability density function for the Wald distribution is

        .. math:: P(x;mean,scale) = \\sqrt{\\frac{scale}{2\\pi x^3}}e^
                                    \\frac{-scale(x-mean)^2}{2\\cdotp mean^2x}

        As noted above the inverse Gaussian distribution first arise
        from attempts to model Brownian motion. It is also a
        competitor to the Weibull for use in reliability modeling and
        modeling stock returns and interest rate processes.

        References
        ----------
        .. [1] Brighton Webs Ltd., Wald Distribution,
               https://web.archive.org/web/20090423014010/http://www.brighton-webs.co.uk:80/distributions/wald.asp
        .. [2] Chhikara, Raj S., and Folks, J. Leroy, "The Inverse Gaussian
               Distribution: Theory : Methodology, and Applications", CRC Press,
               1988.
        .. [3] Wikipedia, "Wald distribution"
               https://en.wikipedia.org/wiki/Wald_distribution

        Examples
        --------
        Draw values from the distribution and plot the histogram:

        >>> import matplotlib.pyplot as plt
        >>> h = plt.hist(randomgen.generator.wald(3, 2, 100000), bins=200, density=True)
        >>> plt.show()

        """
        return cont(&legacy_wald, self._aug_state, size, self.lock, 2,
                    mean, 'mean', CONS_POSITIVE,
                    scale, 'scale', CONS_POSITIVE,
                    0.0, '', CONS_NONE, None)

    

    def negative_binomial(self, n, p, size=None):
        """
        negative_binomial(n, p, size=None)

        Draw samples from a negative binomial distribution.

        Samples are drawn from a negative binomial distribution with specified
        parameters, `n` successes and `p` probability of success where `n` is an
        integer > 0 and `p` is in the interval [0, 1].

        Parameters
        ----------
        n : int or array_like of ints
            Parameter of the distribution, > 0. Floats are also accepted,
            but they will be truncated to integers.
        p : float or array_like of floats
            Parameter of the distribution, >= 0 and <=1.
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  If size is ``None`` (default),
            a single value is returned if ``n`` and ``p`` are both scalars.
            Otherwise, ``np.broadcast(n, p).size`` samples are drawn.

        Returns
        -------
        out : ndarray or scalar
            Drawn samples from the parameterized negative binomial distribution,
            where each sample is equal to N, the number of failures that
            occurred before a total of n successes was reached.

        Notes
        -----
        The probability density for the negative binomial distribution is

        .. math:: P(N;n,p) = \\binom{N+n-1}{N}p^{n}(1-p)^{N},

        where :math:`n` is the number of successes, :math:`p` is the
        probability of success, and :math:`N+n` is the number of trials.
        The negative binomial distribution gives the probability of N
        failures given n successes, with a success on the last trial.

        If one throws a die repeatedly until the third time a "1" appears,
        then the probability distribution of the number of non-"1"s that
        appear before the third "1" is a negative binomial distribution.

        References
        ----------
        .. [1] Weisstein, Eric W. "Negative Binomial Distribution." From
               MathWorld--A Wolfram Web Resource.
               http://mathworld.wolfram.com/NegativeBinomialDistribution.html
        .. [2] Wikipedia, "Negative binomial distribution",
               https://en.wikipedia.org/wiki/Negative_binomial_distribution

        Examples
        --------
        Draw samples from the distribution:

        A real world example. A company drills wild-cat oil
        exploration wells, each with an estimated probability of
        success of 0.1.  What is the probability of having one success
        for each successive well, that is what is the probability of a
        single success after drilling 5 wells, after 6 wells, etc.?

        >>> s = randomgen.generator.negative_binomial(1, 0.9, 100000)
        >>> for i in range(1, 11): # doctest: +SKIP
        ...    probability = sum(s<i) / 100000.
        ...    print(i, "wells drilled, probability of one success =", probability)

        """
        return disc(&legacy_negative_binomial, self._aug_state, size, self.lock, 2, 0,
                        n, 'n', CONS_POSITIVE,
                        p, 'p', CONS_BOUNDED_0_1,
                        0.0, '', CONS_NONE)

    def multivariate_normal(self, mean, cov, size=None, check_valid='warn',
                            tol=1e-8):
        """
        multivariate_normal(self, mean, cov, size=None, check_valid='warn', tol=1e-8)

        Draw random samples from a multivariate normal distribution.

        The multivariate normal, multinormal or Gaussian distribution is a
        generalization of the one-dimensional normal distribution to higher
        dimensions.  Such a distribution is specified by its mean and
        covariance matrix.  These parameters are analogous to the mean
        (average or "center") and variance (standard deviation, or "width,"
        squared) of the one-dimensional normal distribution.

        Parameters
        ----------
        mean : 1-D array_like, of length N
            Mean of the N-dimensional distribution.
        cov : 2-D array_like, of shape (N, N)
            Covariance matrix of the distribution. It must be symmetric and
            positive-semidefinite for proper sampling.
        size : int or tuple of ints, optional
            Given a shape of, for example, ``(m,n,k)``, ``m*n*k`` samples are
            generated, and packed in an `m`-by-`n`-by-`k` arrangement.  Because
            each sample is `N`-dimensional, the output shape is ``(m,n,k,N)``.
            If no shape is specified, a single (`N`-D) sample is returned.
        check_valid : { 'warn', 'raise', 'ignore' }, optional
            Behavior when the covariance matrix is not positive semidefinite.
        tol : float, optional
            Tolerance when checking the singular values in covariance matrix.

        Returns
        -------
        out : ndarray
            The drawn samples, of shape *size*, if that was provided.  If not,
            the shape is ``(N,)``.

            In other words, each entry ``out[i,j,...,:]`` is an N-dimensional
            value drawn from the distribution.

        Notes
        -----
        The mean is a coordinate in N-dimensional space, which represents the
        location where samples are most likely to be generated.  This is
        analogous to the peak of the bell curve for the one-dimensional or
        univariate normal distribution.

        Covariance indicates the level to which two variables vary together.
        From the multivariate normal distribution, we draw N-dimensional
        samples, :math:`X = [x_1, x_2, ... x_N]`.  The covariance matrix
        element :math:`C_{ij}` is the covariance of :math:`x_i` and :math:`x_j`.
        The element :math:`C_{ii}` is the variance of :math:`x_i` (i.e. its
        "spread").

        Instead of specifying the full covariance matrix, popular
        approximations include:

          - Spherical covariance (`cov` is a multiple of the identity matrix)
          - Diagonal covariance (`cov` has non-negative elements, and only on
            the diagonal)

        This geometrical property can be seen in two dimensions by plotting
        generated data-points:

        >>> mean = [0, 0]
        >>> cov = [[1, 0], [0, 100]]  # diagonal covariance

        Diagonal covariance means that points are oriented along x or y-axis:

        >>> import matplotlib.pyplot as plt
        >>> x, y = randomgen.generator.multivariate_normal(mean, cov, 5000).T
        >>> plt.plot(x, y, 'x')
        >>> plt.axis('equal')
        >>> plt.show()

        Note that the covariance matrix must be positive semidefinite (a.k.a.
        nonnegative-definite). Otherwise, the behavior of this method is
        undefined and backwards compatibility is not guaranteed.

        References
        ----------
        .. [1] Papoulis, A., "Probability, Random Variables, and Stochastic
               Processes," 3rd ed., New York: McGraw-Hill, 1991.
        .. [2] Duda, R. O., Hart, P. E., and Stork, D. G., "Pattern
               Classification," 2nd ed., New York: Wiley, 2001.

        Examples
        --------
        >>> mean = (1, 2)
        >>> cov = [[1, 0], [0, 1]]
        >>> x = randomgen.generator.multivariate_normal(mean, cov, (3, 3))
        >>> x.shape
        (3, 3, 2)

        The following is probably true, given that 0.6 is roughly twice the
        standard deviation:

        >>> list((x[0,0,:] - mean) < 0.6)
        [True, True]

        """
        from numpy.dual import svd

        # Check preconditions on arguments
        mean = np.array(mean)
        cov = np.array(cov)
        if size is None:
            shape = []
        elif isinstance(size, (int, long, np.integer)):
            shape = [size]
        else:
            shape = size

        if len(mean.shape) != 1:
               raise ValueError("mean must be 1 dimensional")
        if (len(cov.shape) != 2) or (cov.shape[0] != cov.shape[1]):
               raise ValueError("cov must be 2 dimensional and square")
        if mean.shape[0] != cov.shape[0]:
               raise ValueError("mean and cov must have same length")

        # Compute shape of output and create a matrix of independent
        # standard normally distributed random numbers. The matrix has rows
        # with the same length as mean and as many rows are necessary to
        # form a matrix of shape final_shape.
        final_shape = list(shape[:])
        final_shape.append(mean.shape[0])
        x = self.standard_normal(final_shape).reshape(-1, mean.shape[0])

        # Transform matrix of standard normals into matrix where each row
        # contains multivariate normals with the desired covariance.
        # Compute A such that dot(transpose(A),A) == cov.
        # Then the matrix products of the rows of x and A has the desired
        # covariance. Note that sqrt(s)*v where (u,s,v) is the singular value
        # decomposition of cov is such an A.
        #
        # Also check that cov is positive-semidefinite. If so, the u.T and v
        # matrices should be equal up to roundoff error if cov is
        # symmetric and the singular value of the corresponding row is
        # not zero. We continue to use the SVD rather than Cholesky in
        # order to preserve current outputs. Note that symmetry has not
        # been checked.

        (u, s, v) = svd(cov)

        if check_valid != 'ignore':
            if check_valid != 'warn' and check_valid != 'raise':
                raise ValueError(
                    "check_valid must equal 'warn', 'raise', or 'ignore'")

            psd = np.allclose(np.dot(v.T * s, v), cov, rtol=tol, atol=tol)
            if not psd:
                if check_valid == 'warn':
                    warnings.warn("covariance is not positive-semidefinite.",
                        RuntimeWarning)
                else:
                    raise ValueError(
                        "covariance is not positive-semidefinite.")

        x = np.dot(x, np.sqrt(s)[:, None] * v)
        x += mean
        x.shape = tuple(final_shape)
        return x

    def dirichlet(self, object alpha, size=None):
        """
        dirichlet(alpha, size=None)

        Draw samples from the Dirichlet distribution.

        Draw `size` samples of dimension k from a Dirichlet distribution. A
        Dirichlet-distributed random variable can be seen as a multivariate
        generalization of a Beta distribution. The Dirichlet distribution
        is a conjugate prior of a multinomial distribution in Bayesian
        inference.

        Parameters
        ----------
        alpha : array
            Parameter of the distribution (k dimension for sample of
            dimension k).
        size : int or tuple of ints, optional
            Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
            ``m * n * k`` samples are drawn.  Default is None, in which case a
            single value is returned.

        Returns
        -------
        samples : ndarray,
            The drawn samples, of shape (size, alpha.ndim).

        Raises
        -------
        ValueError
            If any value in alpha is less than or equal to zero

        Notes
        -----
        The Dirichlet distribution is a distribution over vectors
        :math:`x` that fulfil the conditions :math:`x_i>0` and
        :math:`\\sum_{i=1}^k x_i = 1`.

        The probability density function :math:`p` of a
        Dirichlet-distributed random vector :math:`X` is
        proportional to

        .. math:: p(x) \\propto \\prod_{i=1}^{k}{x^{\\alpha_i-1}_i},

        where :math:`\\alpha` is a vector containing the positive
        concentration parameters.

        The method uses the following property for computation: let :math:`Y`
        be a random vector which has components that follow a standard gamma
        distribution, then :math:`X = \\frac{1}{\\sum_{i=1}^k{Y_i}} Y`
        is Dirichlet-distributed

        References
        ----------
        .. [1] David McKay, "Information Theory, Inference and Learning
               Algorithms," chapter 23,
               http://www.inference.org.uk/mackay/itila/
        .. [2] Wikipedia, "Dirichlet distribution",
               https://en.wikipedia.org/wiki/Dirichlet_distribution

        Examples
        --------
        Taking an example cited in Wikipedia, this distribution can be used if
        one wanted to cut strings (each of initial length 1.0) into K pieces
        with different lengths, where each piece had, on average, a designated
        average length, but allowing some variation in the relative sizes of
        the pieces.

        >>> s = randomgen.generator.dirichlet((10, 5, 3), 20).transpose()

        >>> import matplotlib.pyplot as plt
        >>> plt.barh(range(20), s[0])
        >>> plt.barh(range(20), s[1], left=s[0], color='g')
        >>> plt.barh(range(20), s[2], left=s[0]+s[1], color='r')
        >>> plt.title("Lengths of Strings")

        """

        #=================
        # Pure python algo
        #=================
        #alpha   = N.atleast_1d(alpha)
        #k       = alpha.size

        #if n == 1:
        #    val = N.zeros(k)
        #    for i in range(k):
        #        val[i]   = sgamma(alpha[i], n)
        #    val /= N.sum(val)
        #else:
        #    val = N.zeros((k, n))
        #    for i in range(k):
        #        val[i]   = sgamma(alpha[i], n)
        #    val /= N.sum(val, axis = 0)
        #    val = val.T

        #return val

        cdef np.npy_intp   k
        cdef np.npy_intp   totsize
        cdef np.ndarray    alpha_arr, val_arr
        cdef double     *alpha_data
        cdef double     *val_data
        cdef np.npy_intp   i, j
        cdef double     acc, invacc

        k           = len(alpha)
        alpha_arr   = <np.ndarray>np.PyArray_FROM_OTF(alpha, np.NPY_DOUBLE, np.NPY_ALIGNED)
        if np.any(np.less_equal(alpha_arr, 0)):
            raise ValueError('alpha <= 0')
        alpha_data  = <double*>np.PyArray_DATA(alpha_arr)

        if size is None:
            shape = (k,)
        else:
            try:
                shape = (operator.index(size), k)
            except:
                shape = tuple(size) + (k,)

        diric   = np.zeros(shape, np.float64)
        val_arr = <np.ndarray>diric
        val_data= <double*>np.PyArray_DATA(val_arr)

        i = 0
        totsize = np.PyArray_SIZE(val_arr)
        with self.lock, nogil:
            while i < totsize:
                acc = 0.0
                for j in range(k):
                    val_data[i+j] = legacy_standard_gamma(self._aug_state,
                                                          alpha_data[j])
                    acc             = acc + val_data[i + j]
                invacc  = 1/acc
                for j in range(k):
                    val_data[i + j]   = val_data[i + j] * invacc
                i = i + k

        return diric
