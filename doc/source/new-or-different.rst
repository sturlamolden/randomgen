.. _new-or-different:

What's New or Different
-----------------------

.. warning::

  The Box-Muller method used to produce NumPy's normals is no longer available
  in :class:`~randomgen.generator.Generator`.  It is not possible to
  reproduce the random values using :class:`~randomgen.generator.Generator`
  for the normal distribution or any other distribution that relies on the
  normal such as the gamma or student's t. If you require backward compatibility, a 
  legacy generator, :class:`~randomgen.mtrand.RandomState`, has been created
  which can fully reproduce the sequence produced by NumPy.


* :func:`~randomgen.entropy.random_entropy` provides access to the system
  source of randomness that is used in cryptographic applications (e.g.,
  ``/dev/urandom`` on Unix).
* Simulate from the complex normal distribution
  (:meth:`~randomgen.generator.Generator.complex_normal`)
* The normal, exponential and gamma generators use 256-step Ziggurat
  methods which are 2-10 times faster than NumPy's default implementation in
  :meth:`~randomgen.generator.Generator.standard_normal`,
  :meth:`~randomgen.generator.Generator.standard_exponential` or
  :meth:`~randomgen.generator.Generator.standard_gamma`.

.. ipython:: python

  from randomgen import Generator, Xoroshiro128
  import numpy.random
  rg = Generator(Xoroshiro128())
  %timeit rg.standard_normal(100000)
  %timeit numpy.random.standard_normal(100000)

.. ipython:: python

  %timeit rg.standard_exponential(100000)
  %timeit numpy.random.standard_exponential(100000)

.. ipython:: python

  %timeit rg.standard_gamma(3.0, 100000)
  %timeit numpy.random.standard_gamma(3.0, 100000)


* The Box-Muller used to produce NumPy's normals is no longer available.
* All bit generators functions to produce doubles, uint64s and
  uint32s via CTypes (:meth:`~randomgen.xoroshiro128.Xoroshiro128.ctypes`)
  and CFFI (:meth:`~randomgen.xoroshiro128.Xoroshiro128.cffi`).  This allows
  the bit generators to be used in numba or in other low-level applications
* The bit generators can be used in downstream projects via Cython.
* Optional ``dtype`` argument that accepts ``np.float32`` or ``np.float64``
  to produce either single or double prevision uniform random variables for
  select core distributions

  * Uniforms (:meth:`~randomgen.generator.Generator.random` and
    :meth:`~randomgen.generator.Generator.rand`)
  * Normals (:meth:`~randomgen.generator.Generator.standard_normal` and
    :meth:`~randomgen.generator.Generator.randn`)
  * Standard Gammas (:meth:`~randomgen.generator.Generator.standard_gamma`)
  * Standard Exponentials (:meth:`~randomgen.generator.Generator.standard_exponential`)

.. ipython:: python

  rg.seed(0)
  rg.random(3, dtype='d')
  rg.seed(0)
  rg.random(3, dtype='f')

* Optional ``out`` argument that allows existing arrays to be filled for
  select core distributions

  * Uniforms (:meth:`~randomgen.generator.Generator.random`)
  * Normals (:meth:`~randomgen.generator.Generator.standard_normal`)
  * Standard Gammas (:meth:`~randomgen.generator.Generator.standard_gamma`)
  * Standard Exponentials (:meth:`~randomgen.generator.Generator.standard_exponential`)

  This allows multithreading to fill large arrays in chunks using suitable
  PRNGs in parallel.

.. ipython:: python

  existing = np.zeros(4)
  rg.random(out=existing[:2])
  print(existing)

* :meth:`~randomgen.generator.Generator.integers` supports broadcasting inputs.

* :meth:`~randomgen.generator.Generator.integers` supports
  drawing from open (default, ``[low, high)``) or closed
  (``[low, high]``) intervals using the keyword argument
  ``endpoint``. Closed intervals are simpler to use when the
  distribution may include the maximum value of a given integer type.

.. ipython:: python

  rg.seed(1234)
  rg.integers(0, np.iinfo(np.int64).max+1)
  rg.seed(1234)
  rg.integers(0, np.iinfo(np.int64).max, endpoint=True)

* The closed interval is particularly helpful when using arrays since
  it avoids object-dtype arrays when sampling from the full range.

.. ipython:: python

  rg.seed(1234)
  lower = np.zeros((2, 1), dtype=np.uint64)
  upper = np.array([10, np.iinfo(np.uint64).max+1], dtype=np.object)
  upper
  rg.integers(lower, upper, dtype=np.uint64)
  rg.seed(1234)
  upper = np.array([10, np.iinfo(np.uint64).max], dtype=np.uint64)
  upper
  rg.integers(lower, upper, endpoint=True, dtype=np.uint64)

* Support for Lemire’s method of generating uniform integers on an
  arbitrary interval by setting ``use_masked=True`` in
  (:meth:`~randomgen.generator.Generator.integers`).

.. ipython:: python
  :okwarning:

  %timeit rg.integers(0, 1535, size=100000, use_masked=False)
  %timeit numpy.random.randint(0, 1535, size=100000)

* :meth:`~randomgen.generator.Generator.multinomial`
  supports multidimensional values of ``n``

.. ipython:: python

  rg.multinomial([10, 100], np.ones(6) / 6.)

* :meth:`~randomgen.generator.Generator.choice`
  is much faster when sampling small amounts from large arrays

.. ipython:: python

  x = np.arange(1000000)
  %timeit rg.choice(x, 10)

* :meth:`~randomgen.generator.Generator.choice`
  supports the ``axis`` keyword to work with multidimensional arrays.

.. ipython:: python

  x = np.reshape(np.arange(20), (2, 10))
  rg.choice(x, 2, axis=1)

* For changes since the previous release, see the :ref:`change-log`
