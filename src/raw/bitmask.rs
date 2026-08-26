use std::num::NonZero;

use super::imp::{BITMASK_MASK, BITMASK_STRIDE, BitMaskWord};
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
    /// Returns a new `BitMask` with the actually-used bits inverted.
    #[inline]
    #[must_use]
    pub fn invert(self) -> Self {
        BitMask(self.0 ^ BITMASK_MASK)
    }

    /// Returns a new `BitMask` with the lowest set bit removed.
    ///
    /// Returns an empty mask if there is no set bit.
    #[inline]
    #[must_use]
    pub fn remove_lowest_bit(self) -> Self {
        BitMask(self.0 & self.0.wrapping_sub(1))
    }
    /// Returns whether the `BitMask` has at least one set bit.
    #[inline]
    pub fn any_bit_set(self) -> bool {
        self.0 != 0
    }

    /// Returns the index of the lowest matched byte in the group, if there is one.
    ///
    /// This is the position of the lowest set bit divided by `BITMASK_STRIDE`, so it is a byte
    /// index within the group rather than a bit offset into the mask.
    #[inline]
    pub fn lowest_set_bit(self) -> Option<usize> {
        NonZero::<BitMaskWord>::new(self.0)
            .map(|nonzero| nonzero.trailing_zeros() as usize / BITMASK_STRIDE)
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

/// Iterator over the contents of a `BitMask`, returning the index of each matched
/// byte in the group as [BitMask::lowest_set_bit] does.
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
