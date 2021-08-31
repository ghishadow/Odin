/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	An arbitrary precision mathematics implementation in Odin.
	For the theoretical underpinnings, see Knuth's The Art of Computer Programming, Volume 2, section 4.3.
	The code started out as an idiomatic source port of libTomMath, which is in the public domain, with thanks.

	This file contains prime finding operations.
*/
package math_big

/*
	Determines if an Integer is divisible by one of the _PRIME_TABLE primes.
	Returns true if it is, false if not. 
*/
internal_int_prime_is_divisible :: proc(a: ^Int, allocator := context.allocator) -> (res: bool, err: Error) {
	assert_if_nil(a);
	context.allocator = allocator;

	internal_clear_if_uninitialized(a) or_return;

	for prime in _private_prime_table {
		rem := #force_inline int_mod_digit(a, prime) or_return;
		if rem == 0 {
			return true, nil;
		}
	}
	/*
		Default to not divisible.
	*/
	return false, nil;
}

/*
	Computes xR**-1 == x (mod N) via Montgomery Reduction.
*/
internal_int_montgomery_reduce :: proc(x, n: ^Int, rho: DIGIT, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;
	/*
		Can the fast reduction [comba] method be used?
		Note that unlike in mul, you're safely allowed *less* than the available columns [255 per default],
		since carries are fixed up in the inner loop.
	*/
	digs := (n.used * 2) + 1;
	if digs < _WARRAY && x.used <= _WARRAY && n.used < _MAX_COMBA {
		return _private_montgomery_reduce_comba(x, n, rho);
	}

	/*
		Grow the input as required
	*/
	internal_grow(x, digs)                                           or_return;
	x.used = digs;

	for ix := 0; ix < n.used; ix += 1 {
		/*
			`mu = ai * rho mod b`
			The value of rho must be precalculated via `int_montgomery_setup()`,
			such that it equals -1/n0 mod b this allows the following inner loop
			to reduce the input one digit at a time.
		*/

		mu := DIGIT((_WORD(x.digit[ix]) * _WORD(rho)) & _WORD(_MASK));

		/*
			a = a + mu * m * b**i
			Multiply and add in place.
		*/
		u  := DIGIT(0);
		iy := int(0);
		for ; iy < n.used; iy += 1 {
			/*
				Compute product and sum.
			*/
			r := (_WORD(mu) * _WORD(n.digit[iy]) + _WORD(u) + _WORD(x.digit[ix + iy]));

			/*
				Get carry.
			*/
			u = DIGIT(r >> _DIGIT_BITS);

			/*
				Fix digit.
			*/
			x.digit[ix + iy] = DIGIT(r & _WORD(_MASK));
		}

		/*
			At this point the ix'th digit of x should be zero.
			Propagate carries upwards as required.
		*/
		for u != 0 {
			x.digit[ix + iy] += u;
			u = x.digit[ix + iy] >> _DIGIT_BITS;
			x.digit[ix + iy] &= _MASK;
			iy += 1;
		}
	}

	/*
		At this point the n.used'th least significant digits of x are all zero,
		which means we can shift x to the right by n.used digits and the
		residue is unchanged.

		x = x/b**n.used.
	*/
	internal_clamp(x);
	internal_shr_digit(x, n.used);

	/*
		if x >= n then x = x - n
	*/
	if internal_cmp_mag(x, n) != -1 {
		return internal_sub(x, x, n);
	}

	return nil;
}

int_montgomery_reduce :: proc(x, n: ^Int, rho: DIGIT, allocator := context.allocator) -> (err: Error) {
	assert_if_nil(x, n);
	context.allocator = allocator;

	internal_clear_if_uninitialized(x, n) or_return;

	return #force_inline internal_int_montgomery_reduce(x, n, rho);
}

/*
	Shifts with subtractions when the result is greater than b.

	The method is slightly modified to shift B unconditionally upto just under
	the leading bit of b.  This saves alot of multiple precision shifting.
*/
internal_int_montgomery_calc_normalization :: proc(a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;
	/*
		How many bits of last digit does b use.
	*/
	bits := internal_count_bits(b) % _DIGIT_BITS;

	if b.used > 1 {
		power := ((b.used - 1) * _DIGIT_BITS) + bits - 1;
		internal_int_power_of_two(a, power)                          or_return;
	} else {
		internal_one(a)                                              or_return;
		bits = 1;
	}

	/*
		Now compute C = A * B mod b.
	*/
	for x := bits - 1; x < _DIGIT_BITS; x += 1 {
		internal_int_shl1(a, a)                                      or_return;
		if internal_cmp_mag(a, b) != -1 {
			internal_sub(a, a, b)                                    or_return;
		}
	}
	return nil;
}

int_montgomery_calc_normalization :: proc(a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	assert_if_nil(a, b);
	context.allocator = allocator;

	internal_clear_if_uninitialized(a, b) or_return;

	return #force_inline internal_int_montgomery_calc_normalization(a, b);
}

/*
	Sets up the Montgomery reduction stuff.
*/
internal_int_montgomery_setup :: proc(n: ^Int) -> (rho: DIGIT, err: Error) {
	/*
		Fast inversion mod 2**k
		Based on the fact that:

		XA = 1 (mod 2**n) => (X(2-XA)) A = 1 (mod 2**2n)
		                  =>  2*X*A - X*X*A*A = 1
		                  =>  2*(1) - (1)     = 1
	*/
	b := n.digit[0];
	if b & 1 == 0 { return 0, .Invalid_Argument; }

	x := (((b + 2) & 4) << 1) + b; /* here x*a==1 mod 2**4 */
	x *= 2 - (b * x);              /* here x*a==1 mod 2**8 */
	x *= 2 - (b * x);              /* here x*a==1 mod 2**16 */

	when _DIGIT_TYPE_BITS == 64 {
		x *= 2 - (b * x);              /* here x*a==1 mod 2**32 */
		x *= 2 - (b * x);              /* here x*a==1 mod 2**64 */
	}

	/*
		rho = -1/m mod b
	*/
	rho = DIGIT(((_WORD(1) << _WORD(_DIGIT_BITS)) - _WORD(x)) & _WORD(_MASK));
	return rho, nil;
}

int_montgomery_setup :: proc(n: ^Int, allocator := context.allocator) -> (rho: DIGIT, err: Error) {
	assert_if_nil(n);
	internal_clear_if_uninitialized(n, allocator) or_return;

	return #force_inline internal_int_montgomery_setup(n);
}

/*
	Reduces `x` mod `m`, assumes 0 < x < m**2, mu is precomputed via reduce_setup.
	From HAC pp.604 Algorithm 14.42

	Assumes `x`, `m` and `mu` all not to be `nil` and have been initialized.
*/
internal_int_reduce :: proc(x, m, mu: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	q := &Int{};
	defer internal_destroy(q);
	um := m.used;

	/*
		q = x
	*/
	internal_copy(q, x)                                              or_return;

	/*
		q1 = x / b**(k-1)
	*/
	internal_shr_digit(q, um - 1);

	/*
		According to HAC this optimization is ok.
	*/
	if DIGIT(um) > DIGIT(1) << (_DIGIT_BITS - 1) {
		internal_mul(q, q, mu)                                       or_return;
	} else {
		_private_int_mul_high(q, q, mu, um)                          or_return;
	}

	/*
		q3 = q2 / b**(k+1)
	*/
	internal_shr_digit(q, um + 1);

	/*
		x = x mod b**(k+1), quick (no division)
	*/
	internal_int_mod_bits(x, x, _DIGIT_BITS * (um + 1))              or_return;

	/*
		q = q * m mod b**(k+1), quick (no division)
	*/
	_private_int_mul(q, q, m, um + 1)                                or_return;

	/*
		x = x - q
	*/
	internal_sub(x, x, q)                                            or_return;

	/*
		If x < 0, add b**(k+1) to it.
	*/
	if internal_cmp(x, 0) == -1 {
		internal_set(q, 1)                                           or_return;
		internal_shl_digit(q, um + 1)                                or_return;
		internal_add(x, x, q)                                        or_return;
	}

	/*
		Back off if it's too big.
	*/
	for internal_cmp(x, m) != -1 {
		internal_sub(x, x, m)                                        or_return;
	}

	return nil;
}

/*
	Reduces `a` modulo `n`, where `n` is of the form 2**p - d.
*/
internal_int_reduce_2k :: proc(a, n: ^Int, d: DIGIT, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	q := &Int{};
	defer internal_destroy(q);

	internal_zero(q)                                                 or_return;

	p := internal_count_bits(n);

	for {
		/*
			q = a/2**p, a = a mod 2**p
		*/
		internal_shrmod(q, a, a, p)                                  or_return;

		if d != 1 {
			/*
				q = q * d
			*/
			internal_mul(q, q, d)                                    or_return;
		}

		/*
			a = a + q
		*/
		internal_add(a, a, q)                                        or_return;
		if internal_cmp_mag(a, n) == -1                              { break; }
		internal_sub(a, a, n)                                        or_return;
	}

	return nil;
}

/*
	Reduces `a` modulo `n` where `n` is of the form 2**p - d
	This differs from reduce_2k since "d" can be larger than a single digit.
*/
internal_int_reduce_2k_l :: proc(a, n, d: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	q := &Int{};
	defer internal_destroy(q);

	internal_zero(q)                                                 or_return;

	p := internal_count_bits(n);

	for {
		/*
			q = a/2**p, a = a mod 2**p
		*/
		internal_shrmod(q, a, a, p)                                  or_return;

		/*
			q = q * d
		*/
		internal_mul(q, q, d)                                        or_return;

		/*
			a = a + q
		*/
		internal_add(a, a, q)                                        or_return;
		if internal_cmp_mag(a, n) == -1                              { break; }
		internal_sub(a, a, n)                                        or_return;
	}

	return nil;
}

/*
	Determines if `internal_int_reduce_2k` can be used.
	Asssumes `a` not to be `nil` and to have been initialized.
*/
internal_int_reduce_is_2k :: proc(a: ^Int) -> (reducible: bool, err: Error) {
	assert_if_nil(a);

	if internal_is_zero(a) {
		return false, nil;
	} else if a.used == 1 {
		return true, nil;
	} else if a.used  > 1 {
		iy := internal_count_bits(a);
		iw := 1;
		iz := DIGIT(1);

		/*
			Test every bit from the second digit up, must be 1.
		*/
		for ix := _DIGIT_BITS; ix < iy; ix += 1 {
			if a.digit[iw] & iz == 0 {
				return false, nil;
			}

			iz <<= 1;
			if iz > _DIGIT_MAX {
				iw += 1;
				iz  = 1;
			}
		}
		return true, nil;
	} else {
		return true, nil;
	}
}

/*
	Determines if `internal_int_reduce_2k_l` can be used.
	Asssumes `a` not to be `nil` and to have been initialized.
*/
internal_int_reduce_is_2k_l :: proc(a: ^Int) -> (reducible: bool, err: Error) {
	assert_if_nil(a);

	if internal_int_is_zero(a) {
		return false, nil;
	} else if a.used == 1 {
		return true, nil;
	} else if a.used  > 1 {
		/*
			If more than half of the digits are -1 we're sold.
		*/
		ix := 0;
		iy := 0;

		for ; ix < a.used; ix += 1 {
			if a.digit[ix] == _DIGIT_MAX {
				iy += 1;
			}
		}
		return iy >= (a.used / 2), nil;
	} else {
		return false, nil;
	}
}

/*
	Determines the setup value.
	Assumes `a` is not `nil`.
*/
internal_int_reduce_2k_setup :: proc(a: ^Int, allocator := context.allocator) -> (d: DIGIT, err: Error) {
	context.allocator = allocator;

	tmp := &Int{};
	defer internal_destroy(tmp);
	internal_zero(tmp)                                               or_return;

	internal_int_power_of_two(tmp, internal_count_bits(a))           or_return;
	internal_sub(tmp, tmp, a)                                        or_return;

	return tmp.digit[0], nil;
}

/*
	Determines the setup value.
	Assumes `mu` and `P` are not `nil`.

	d := (1 << a.bits) - a;
*/
internal_int_reduce_2k_setup_l :: proc(mu, P: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	tmp := &Int{};
	defer internal_destroy(tmp);
	internal_zero(tmp)                                               or_return;

	internal_int_power_of_two(tmp, internal_count_bits(P))           or_return;
	internal_sub(mu, tmp, P)                                         or_return;

	return nil;
}

/*
	Pre-calculate the value required for Barrett reduction.
	For a given modulus "P" it calulates the value required in "mu"
	Assumes `mu` and `P` are not `nil`.
*/
internal_int_reduce_setup :: proc(mu, P: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	internal_int_power_of_two(mu, P.used * 2 * _DIGIT_BITS)           or_return;
	return internal_int_div(mu, mu, P);
}

/*
	Computes res == G**X mod P.
	Assumes `res`, `G`, `X` and `P` to not be `nil` and for `G`, `X` and `P` to have been initialized.
*/
internal_int_exponent_mod :: proc(res, G, X, P: ^Int, redmode: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	M := [_TAB_SIZE]Int{};
	winsize: uint;

	/*
		Use a pointer to the reduction algorithm.
		This allows us to use one of many reduction algorithms without modding the guts of the code with if statements everywhere.
	*/
	redux: #type proc(x, m, mu: ^Int, allocator := context.allocator) -> (err: Error);

	defer {
		internal_destroy(&M[1]);
		for x := 1 << (winsize - 1); x < (1 << winsize); x += 1 {
			internal_destroy(&M[x]);
		}
	}

	/*
		Find window size.
	*/
	x := internal_count_bits(X);
	switch {
	case x <= 7:
		winsize = 2;
	case x <= 36:
		winsize = 3;
	case x <= 140:
		winsize = 4;
	case x <= 450:
		winsize = 5;
	case x <= 1303:
		winsize = 6;
	case x <= 3529:
		winsize = 7;
	case:
		winsize = 8;
	}

	winsize = min(_MAX_WIN_SIZE, winsize) if _MAX_WIN_SIZE > 0 else winsize;

	/*
		Init M array.
		Init first cell.
	*/
	internal_zero(&M[1])                                             or_return;

	/*
		Now init the second half of the array.
	*/
	for x = 1 << (winsize - 1); x < (1 << winsize); x += 1 {
		internal_zero(&M[x])                                         or_return;
	}

	/*
		Create `mu`, used for Barrett reduction.
	*/
	mu := &Int{};
	defer internal_destroy(mu);
	internal_zero(mu)                                                or_return;

	if redmode == 0 {
		internal_int_reduce_setup(mu, P)                             or_return;
		redux = internal_int_reduce;
	} else {
		internal_int_reduce_2k_setup_l(mu, P)                        or_return;
		redux = internal_int_reduce_2k_l;
	}

	/*
		Create M table.

		The M table contains powers of the base, e.g. M[x] = G**x mod P.
		The first half of the table is not computed, though, except for M[0] and M[1].
	*/
	internal_int_mod(&M[1], G, P)                                    or_return;

	/*
		Compute the value at M[1<<(winsize-1)] by squaring M[1] (winsize-1) times.

		TODO: This can probably be replaced by computing the power and using `pow` to raise to it
		instead of repeated squaring.
	*/
	slot := 1 << (winsize - 1);
	internal_copy(&M[slot], &M[1])                                   or_return;

	for x = 0; x < int(winsize - 1); x += 1 {
		/*
			Square it.
		*/
		internal_sqr(&M[slot], &M[slot])                             or_return;

		/*
			Reduce modulo P
		*/
		redux(&M[slot], P, mu)                                       or_return;
	}

	/*
		Create upper table, that is M[x] = M[x-1] * M[1] (mod P)
		for x = (2**(winsize - 1) + 1) to (2**winsize - 1)
	*/
	for x = slot + 1; x < (1 << winsize); x += 1 {
		internal_mul(&M[x], &M[x - 1], &M[1])                        or_return;
		redux(&M[x], P, mu)                                          or_return;
	}

	/*
		Setup result.
	*/
	internal_one(res)                                                or_return;

	/*
		Set initial mode and bit cnt.
	*/
	mode   := 0;
	bitcnt := 1;
	buf    := DIGIT(0);
	digidx := X.used - 1;
	bitcpy := uint(0);
	bitbuf := DIGIT(0);

	for {
		/*
			Grab next digit as required.
		*/
		bitcnt -= 1;
		if bitcnt == 0 {
			/*
				If digidx == -1 we are out of digits.
			*/
			if digidx == -1 { break; }

			/*
				Read next digit and reset the bitcnt.
			*/
			buf    = X.digit[digidx];
			digidx -= 1;
			bitcnt = _DIGIT_BITS;
		}

		/*
			Grab the next msb from the exponent.
		*/
		y := buf >> (_DIGIT_BITS - 1) & 1;
		buf <<= 1;

		/*
			If the bit is zero and mode == 0 then we ignore it.
			These represent the leading zero bits before the first 1 bit
			in the exponent.  Technically this opt is not required but it
			does lower the # of trivial squaring/reductions used.
		*/
		if mode == 0 && y == 0 {
			continue;
		}

		/*
			If the bit is zero and mode == 1 then we square.
		*/
		if mode == 1 && y == 0 {
			internal_sqr(res, res)                                   or_return;
			redux(res, P, mu)                                        or_return;
			continue;
		}

		/*
			Else we add it to the window.
		*/
		bitcpy += 1;
		bitbuf |= (y << (winsize - bitcpy));
		mode    = 2;

		if (bitcpy == winsize) {
			/*
				Window is filled so square as required and multiply.
				Square first.
			*/
			for x = 0; x < int(winsize); x += 1 {
				internal_sqr(res, res)                               or_return;
				redux(res, P, mu)                                    or_return;
			}

			/*
				Then multiply.
			*/
			internal_mul(res, res, &M[bitbuf])                       or_return;
			redux(res, P, mu)                                        or_return;

			/*
				Empty window and reset.
			*/
			bitcpy = 0;
			bitbuf = 0;
			mode   = 1;
		}
	}

	/*
		If bits remain then square/multiply.
	*/
	if mode == 2 && bitcpy > 0 {
		/*
			Square then multiply if the bit is set.
		*/
		for x = 0; x < int(bitcpy); x += 1 {
			internal_sqr(res, res)                                   or_return;
			redux(res, P, mu)                                        or_return;

			bitbuf <<= 1;
			if ((bitbuf & (1 << winsize)) != 0) {
				/*
					Then multiply.
				*/
				internal_mul(res, res, &M[1])                        or_return;
				redux(res, P, mu)                                    or_return;
			}
		}
	}
	return err;
}

/*
	Computes Y == G**X mod P, HAC pp.616, Algorithm 14.85

	Uses a left-to-right `k`-ary sliding window to compute the modular exponentiation.
	The value of `k` changes based on the size of the exponent.

	Uses Montgomery or Diminished Radix reduction [whichever appropriate]

	Assumes `res`, `G`, `X` and `P` to not be `nil` and for `G`, `X` and `P` to have been initialized.
*/
internal_int_exponent_mod_fast :: proc(res, G, X, P: ^Int, redmode: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	M := [_TAB_SIZE]Int{};
	winsize: uint;

	/*
		Use a pointer to the reduction algorithm.
		This allows us to use one of many reduction algorithms without modding the guts of the code with if statements everywhere.
	*/
	redux: #type proc(x, n: ^Int, rho: DIGIT, allocator := context.allocator) -> (err: Error);

	defer {
		internal_destroy(&M[1]);
		for x := 1 << (winsize - 1); x < (1 << winsize); x += 1 {
			internal_destroy(&M[x]);
		}
	}

	/*
		Find window size.
	*/
	x := internal_count_bits(X);
	switch {
	case x <= 7:
		winsize = 2;
	case x <= 36:
		winsize = 3;
	case x <= 140:
		winsize = 4;
	case x <= 450:
		winsize = 5;
	case x <= 1303:
		winsize = 6;
	case x <= 3529:
		winsize = 7;
	case:
		winsize = 8;
	}

	winsize = min(_MAX_WIN_SIZE, winsize) if _MAX_WIN_SIZE > 0 else winsize;

	/*
		Init M array
		Init first cell.
	*/
	cap := internal_int_allocated_cap(P);
	internal_grow(&M[1], cap)                                        or_return;

	/*
		Now init the second half of the array.
	*/
	for x = 1 << (winsize - 1); x < (1 << winsize); x += 1 {
		internal_grow(&M[x], cap)                                    or_return;
	}

	/*
		Determine and setup reduction code.
	*/
	rho: DIGIT;

	if redmode == 0 {
		/*
			Now setup Montgomery.
		*/
		rho = internal_int_montgomery_setup(P)                       or_return;

		/*
			Automatically pick the comba one if available (saves quite a few calls/ifs).
		*/
		if ((P.used * 2) + 1) < _WARRAY && P.used < _MAX_COMBA {
			redux = _private_montgomery_reduce_comba;
		} else {
			/*
				Use slower baseline Montgomery method.
			*/
			redux = internal_int_montgomery_reduce;
		}
	} else if redmode == 1 {
		/*
		if (MP_HAS(MP_DR_SETUP) && MP_HAS(MP_DR_REDUCE)) {
			/* setup DR reduction for moduli of the form B**k - b */
			mp_dr_setup(P, &mp);
			redux = mp_dr_reduce;
		} else {
			err = MP_VAL;
			goto LBL_M;
		}
		*/
		return .Unimplemented;
	} else {
		/*
			Setup DR reduction for moduli of the form 2**k - b.
		*/
		rho = internal_int_reduce_2k_setup(P)                        or_return;
		redux = internal_int_reduce_2k;
	}

	/*
		Setup result.
	*/
	internal_grow(res, cap)                                          or_return;

	/*
		Create M table
		The first half of the table is not computed, though, except for M[0] and M[1]
	*/

	if redmode == 0 {
		/*
			Now we need R mod m.
		*/
		internal_int_montgomery_calc_normalization(res, P)           or_return;

		/*
			Now set M[1] to G * R mod m.
		*/
		internal_mulmod(&M[1], G, res, P)                            or_return;
	} else {
		internal_one(res)                                            or_return;
		internal_mod(&M[1], G, P)                                    or_return;
	}

	/*
		Compute the value at M[1<<(winsize-1)] by squaring M[1] (winsize-1) times.
	*/
	slot := 1 << (winsize - 1);
	internal_copy(&M[slot], &M[1])                                   or_return;

	for x = 0; x < int(winsize - 1); x += 1 {
		internal_sqr(&M[slot], &M[slot])                             or_return;
   		print("slot: ", &M[slot]);
		redux(&M[slot], P, rho)                                      or_return;
		print("slot redux: ", &M[slot]);
	}

	/*
		Create upper table.
	*/
	for x = (1 << (winsize - 1)) + 1; x < (1 << winsize); x += 1 {
		internal_mul(&M[x], &M[x - 1], &M[1])                        or_return;
		redux(&M[x], P, rho)                                         or_return;
	}

	/*
		Set initial mode and bit cnt.
	*/
	mode   := 0;
	bitcnt := 1;
	buf    := DIGIT(0);
	digidx := X.used - 1;
	bitcpy := 0;
	bitbuf := DIGIT(0);

	for {
		/*
			Grab next digit as required.
		*/
		bitcnt -= 1;
		if bitcnt == 0 {
			/*
				If digidx == -1 we are out of digits so break.
			*/
			if digidx == -1 { break; }

			/*
				Read next digit and reset the bitcnt.
			*/
			buf    = X.digit[digidx];
			digidx -= 1;
			bitcnt = _DIGIT_BITS;
		}

		/*
			Grab the next msb from the exponent.
		*/
		y := (buf >> (_DIGIT_BITS - 1)) & 1;
		buf <<= 1;

		/*
			If the bit is zero and mode == 0 then we ignore it.
			These represent the leading zero bits before the first 1 bit in the exponent.
			Technically this opt is not required but it does lower the # of trivial squaring/reductions used.
		*/
		if mode == 0 && y == 0 { continue; }

		/*
			If the bit is zero and mode == 1 then we square.
		*/
		if mode == 1 && y == 0 {
			internal_sqr(res, res)                                   or_return;
			redux(res, P, rho)                                       or_return;
			continue;
		}

		/*
			Else we add it to the window.
		*/
		bitcpy += 1;
		bitbuf |= (y << (winsize - uint(bitcpy)));
		mode    = 2;

		if bitcpy == int(winsize) {
			/*
				Window is filled so square as required and multiply
				Square first.
			*/
			for x = 0; x < int(winsize); x += 1 {
				internal_sqr(res, res)                               or_return;
				redux(res, P, rho)                                   or_return;
			}

			/*
				Then multiply.
			*/
			internal_mul(res, res, &M[bitbuf])                       or_return;
			redux(res, P, rho)                                       or_return;

			/*
				Empty window and reset.
			*/
			bitcpy = 0;
			bitbuf = 0;
			mode   = 1;
		}
	}

	/*
		If bits remain then square/multiply.
	*/
	if mode == 2 && bitcpy > 0 {
		/*
			Square then multiply if the bit is set.
		*/
		for x = 0; x < bitcpy; x += 1 {
			internal_sqr(res, res)                                   or_return;
			redux(res, P, rho)                                       or_return;

			/*
				Get next bit of the window.
			*/
			bitbuf <<= 1;
			if bitbuf & (1 << winsize) != 0 {
				/*
					Then multiply.
				*/
				internal_mul(res, res, &M[1])                        or_return;
				redux(res, P, rho)                                   or_return;
			}
		}
	}

	if redmode == 0 {
		/*
			Fixup result if Montgomery reduction is used.
			Recall that any value in a Montgomery system is actually multiplied by R mod n.
			So we have to reduce one more time to cancel out the factor of R.
		*/
		redux(res, P, rho)                                           or_return;
	}

	return nil;
}

/*
	Returns the number of Rabin-Miller trials needed for a given bit size.
*/
number_of_rabin_miller_trials :: proc(bit_size: int) -> (number_of_trials: int) {
	switch {
	case bit_size <=    80:
		return - 1;		/* Use deterministic algorithm for size <= 80 bits */
	case bit_size >=    81 && bit_size <     96:
		return 37;		/* max. error = 2^(-96)  */
	case bit_size >=    96 && bit_size <    128:
		return 32;		/* max. error = 2^(-96)  */
	case bit_size >=   128 && bit_size <    160:
		return 40;		/* max. error = 2^(-112) */
	case bit_size >=   160 && bit_size <    256:
		return 35;		/* max. error = 2^(-112) */
	case bit_size >=   256 && bit_size <    384:
		return 27;		/* max. error = 2^(-128) */
	case bit_size >=   384 && bit_size <    512:
		return 16;		/* max. error = 2^(-128) */
	case bit_size >=   512 && bit_size <    768:
		return 18;		/* max. error = 2^(-160) */
	case bit_size >=   768 && bit_size <    896:
		return 11;		/* max. error = 2^(-160) */
	case bit_size >=   896 && bit_size <  1_024:
		return 10;		/* max. error = 2^(-160) */
	case bit_size >= 1_024 && bit_size <  1_536:
		return 12;		/* max. error = 2^(-192) */
	case bit_size >= 1_536 && bit_size <  2_048:
		return  8;		/* max. error = 2^(-192) */
	case bit_size >= 2_048 && bit_size <  3_072:
		return  6;		/* max. error = 2^(-192) */
	case bit_size >= 3_072 && bit_size <  4_096:
		return  4;		/* max. error = 2^(-192) */
	case bit_size >= 4_096 && bit_size <  5_120:
		return  5;		/* max. error = 2^(-256) */
	case bit_size >= 5_120 && bit_size <  6_144:
		return  4;		/* max. error = 2^(-256) */
	case bit_size >= 6_144 && bit_size <  8_192:
		return  4;		/* max. error = 2^(-256) */
	case bit_size >= 8_192 && bit_size <  9_216:
		return  3;		/* max. error = 2^(-256) */
	case bit_size >= 9_216 && bit_size < 10_240:
		return  3;		/* max. error = 2^(-256) */
	case:
		return  2;		/* For keysizes bigger than 10_240 use always at least 2 Rounds */
	}
}