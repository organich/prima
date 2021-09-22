! This is a module evaluating the objective/constraint function with Nan/Inf handling.
!
! Coded by Zaikun ZHANG (www.zhangzk.net).
!
! Started: August 2021
!
! Last Modified: Wednesday, September 22, 2021 AM11:48:40


module evaluate_mod

implicit none
private
public :: evalf, evalfc


contains


subroutine evalf(calfun, x, f)

! Generic modules
use, non_intrinsic :: consts_mod, only : RP, HUGEFUN
use, non_intrinsic :: infnan_mod, only : is_nan
use, non_intrinsic :: pintrf_mod, only : FUN

implicit none

! Inputs
procedure(FUN) :: calfun
real(RP), intent(in) :: x(:)

! Output
real(RP), intent(out) :: f

if (any(is_nan(x))) then
    ! Set F to NaN. This is necessary if the initial X contains NaN.
    f = sum(x)
else
    call calfun(x, f)  ! Evaluate F.

    ! Moderated extreme barrier: replace NaN/huge objective or constraint values with a large but
    ! finite value. This is naive, and better approaches surely exist.
    if (f > HUGEFUN .or. is_nan(f)) then
        f = HUGEFUN
    end if

    !! We may moderate huge negative values of F (NOT an extreme barrier), but we decide not to.
    !!f = max(-HUGEFUN, f)
end if

end subroutine evalf


subroutine evalfc(calcfc, x, f, constr, cstrv)

! Generic modules
use, non_intrinsic :: consts_mod, only : RP, ZERO, HUGEFUN, HUGECON
use, non_intrinsic :: infnan_mod, only : is_nan
use, non_intrinsic :: pintrf_mod, only : FUNCON

implicit none

! Inputs
procedure(FUNCON) :: calcfc
real(RP), intent(in) :: x(:)

! Outputs
real(RP), intent(out) :: f
real(RP), intent(out) :: constr(:)
real(RP), intent(out) :: cstrv

if (any(is_nan(x))) then
    ! Set F and CONSTR to NaN. This is necessary if the initial X contains NaN.
    f = sum(x)
    constr = f
    cstrv = f
else
    call calcfc(x, f, constr)  ! Evaluate F and CONSTR.

    ! Moderated extreme barrier: replace NaN/huge objective or constraint values with a large but
    ! finite value. This is naive, and better approaches surely exist.
    if (f > HUGEFUN .or. is_nan(f)) then
        f = HUGEFUN
    end if
    where (constr < -HUGECON .or. is_nan(constr))
        ! The constraint is CONSTR(X) >= 0, so NaN should be replaced with a large negative value.
        constr = -HUGECON  ! MATLAB code: constr(constr < -HUGECON | isnan(constr)) = -HUGECON
    end where

    ! Moderate huge positive values of CONSTR, or they may lead to Inf/NaN in subsequent calculations.
    ! This is NOT an extreme barrier.
    constr = min(HUGECON, constr)
    !! We may moderate F similarly, but we decide not to.
    !!f = max(-HUGEFUN, f)

    ! Evaluate the constraint violation for constraints CONSTR(X) >= 0.
    cstrv = maxval([-constr, ZERO])
end if

end subroutine evalfc


end module evaluate_mod
