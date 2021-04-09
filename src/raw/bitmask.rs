use super::imp::{BitMaskWord, BITMASK_MASK, BITMASK_STRIDE};
#[cfg(feature = "nightly")]
use core::intrinsics;

/// A bit mask which contains the result of a `Match` operation on a `Group` and
/// allows iterating through them.
///
/// The bit mask is arranged so that low-order bits represent lower memory
/// addresses for group match results.
///
/// For implementation reasons, the bits in the set may be sparsely packed, so
/// that there is only one bit-per-byte used (the high bit, 7). If this is the
/// case, `BITMASK_STRIDE` will be 8 to indicate a divide-by-8 should be
/// performed on counts/indices to normalize this difference. `BITMASK_MASK` is
/// similarly a mask of all the actually-used bits.
#[derive(Copy, Clone)]
pub struct BitMask(pub BitMaskWord);

#[allow(clippy::use_self)]
impl BitMask {
    /// Returns a new `BitMask` with all bits inverted.
    #[inline]
    #[must_use]
    pub fn invert(self) -> Self {
        BitMask(self.0 ^ BITMASK_MASK)
    }

    /// Flip the bit in the mask for the entry at the given index.
    ///
    /// Returns the bit's previous state.
    #[inline]
    #[allow(clippy::cast_ptr_alignment)]
    #[cfg(feature = "raw")]
    pub unsafe fn flip(&mut self, index: usize) -> bool {
        // NOTE: The + BITMASK_STRIDE - 1 is to set the high bit.
        let mask = 1 << (index * BITMASK_STRIDE + BITMASK_STRIDE - 1);
        self.0 ^= mask;
        // The bit was set if the bit is now 0.
        self.0 & mask == 0
    }

    /// Returns a new `BitMask` with the lowest bit removed.
    #[inline]
    #[must_use]
    pub fn remove_lowest_bit(self) -> Self {
        BitMask(self.0 & (self.0 - 1))
    }
    /// Returns whether the `BitMask` has at least one set bit.
    #[inline]
    pub fn any_bit_set(self) -> bool {
        self.0 != 0
    }

    /// Returns the first set bit in the `BitMask`, if there is one.
    #[inline]
    pub fn lowest_set_bit(self) -> Option<usize> {
        if self.0 == 0 {
            None
        } else {
            Some(unsafe { self.lowest_set_bit_nonzero() })
        }
    }

    /// Returns the first set bit in the `BitMask`, if there is one. The
    /// bitmask must not be empty.
    #[inline]
    #[cfg(feature = "nightly")]
    pub unsafe fn lowest_set_bit_nonzero(self) -> usize {
        intrinsics::cttz_nonzero(self.0) as usize / BITMASK_STRIDE
    }
    #[inline]
    #[cfg(not(feature = "nightly"))]
    pub unsafe fn lowest_set_bit_nonzero(self) -> usize {
        self.trailing_zeros()
    }
}

impl IntoIterator for BitMask {
    type Item = usize;
    type IntoIter = BitMaskIter;

    #[inline]
    fn into_iter(self) -> BitMaskIter {
        BitMaskIter(self)
    }
}

/// Iterator over the contents of a `BitMask`, returning the indicies of set
/// bits.
pub struct BitMaskIter(BitMask);

impl Iterator for BitMaskIter {
    type Item = usize;

    #[inline]
    fn next(&mut self) -> Option<usize> {
        let bit = self.0.lowest_set_bit()?;
        self.0 = self.0.remove_lowest_bit();
        Some(bit)
    }
}
