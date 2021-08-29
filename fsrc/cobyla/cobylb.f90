module cobylb_mod

implicit none
private
public :: cobylb


contains

subroutine cobylb(iprint, maxfun, ctol, ftarget, rhobeg, rhoend, constr, x, nf, chist, conhist, cstrv, f, fhist, xhist, info)

! Generic modules
use consts_mod, only : RP, IK, ZERO, TWO, HALF, QUART, TENTH, HUGENUM, DEBUGGING
use info_mod, only : FTARGET_ACHIEVED, MAXFUN_REACHED, MAXTR_REACHED, &
    & SMALL_TR_RADIUS, NAN_X, NAN_INF_F, NAN_MODEL, DAMAGING_ROUNDING
use infnan_mod, only : is_nan, is_posinf
use debug_mod, only : errstop, verisize
use output_mod, only : retmssg, rhomssg, fmssg
use lina_mod, only : inprod, matprod, outprod, inv
use selectx_mod, only : selectx

! Solver-specific modules
use initialize_mod, only : initxfc, initfilt
use trustregion_mod, only : trstlp
use update_mod, only : updatepole, findpole
use geometry_mod, only : goodgeo, setdrop_geo, setdrop_tr, geostep
use history_mod, only : savehist, savefilt

implicit none

! Inputs
integer(IK), intent(in) :: iprint
integer(IK), intent(in) :: maxfun
real(RP), intent(in) :: ctol
real(RP), intent(in) :: ftarget
real(RP), intent(in) :: rhobeg
real(RP), intent(in) :: rhoend

! In-outputs
real(RP), intent(out) :: constr(:) ! M
real(RP), intent(inout) :: x(:)  ! N

! Outputs
integer(IK), intent(out) :: info
integer(IK), intent(out) :: nf
real(RP), intent(out) :: chist(:)
real(RP), intent(out) :: conhist(:, :)
real(RP), intent(out) :: cstrv
real(RP), intent(out) :: f
real(RP), intent(out) :: fhist(:)
real(RP), intent(out) :: xhist(:, :)

! Parameter
integer(IK), parameter :: maxfilt = 2000_IK  ! Must be positive. Recommended to be in [100, 10,000].

! Local variables
integer(IK) :: tr
integer(IK) :: maxtr
integer(IK) :: jdrop
integer(IK) :: kopt
integer(IK) :: m
integer(IK) :: maxxhist
integer(IK) :: maxfhist
integer(IK) :: maxconhist
integer(IK) :: maxchist
integer(IK) :: maxhist

integer(IK) :: n
integer(IK) :: nfilt
integer(IK) :: subinfo
real(RP) :: A(size(x), size(constr) + 1)
! A(:, 1:M) contains the approximate gradient for the constraints, and A(:, M+1) is minus the
! approximate gradient for the objective function.
real(RP) :: actrem
real(RP) :: b(size(constr) + 1)
real(RP) :: barmu
real(RP) :: cfilt(min(max(maxfilt, 0), maxfun))
real(RP) :: cmax(size(constr))
real(RP) :: cmin(size(constr))
real(RP) :: confilt(size(constr), size(cfilt))
real(RP) :: conmat(size(constr), size(x) + 1)
real(RP) :: cpen  ! Penalty parameter for constraint in merit function (PARMU in Powell's code)
real(RP) :: cval(size(x) + 1)
real(RP) :: d(size(x))
real(RP) :: denom
real(RP) :: factor_alpha
real(RP) :: factor_beta
real(RP) :: factor_delta
real(RP) :: factor_gamma
real(RP) :: ffilt(size(cfilt))
real(RP) :: fval(size(x) + 1)
real(RP) :: prerec  ! Predicted reduction in Constraint violation
real(RP) :: preref  ! Predicted reduction in objective Function
real(RP) :: prerem  ! Predicted reduction in Merit function
real(RP) :: rho
real(RP) :: sim(size(x), size(x) + 1)  ! (n, )
real(RP) :: simi(size(x), size(x))  ! (n, )
real(RP) :: simi_jdrop(size(x))
real(RP) :: xfilt(size(x), size(cfilt))
logical :: evaluated(size(x) + 1)
logical :: bad_trstep
logical :: good_geo
logical :: improve_geo
logical :: reduce_rho
logical :: shortd
character(len=*), parameter :: srname = 'COBYLB'

reduce_rho = .false.

! Get and verify the sizes.
m = size(constr)
n = size(x)
maxxhist = size(xhist, 2)
maxfhist = size(fhist)
maxconhist = size(conhist, 2)
maxchist = size(chist)
maxhist = max(maxxhist, maxfhist, maxconhist, maxchist)
if (DEBUGGING) then
    if (n < 1) then
        call errstop(srname, 'SIZE(X) < 1')
    end if
    if (maxxhist > 0) then
        call verisize(xhist, n, maxhist)
    end if
    if (maxfhist > 0) then
        call verisize(fhist, maxhist)
    end if
    if (maxconhist > 0) then
        call verisize(conhist, m, maxhist)
    end if
    if (maxchist > 0) then
        call verisize(chist, maxhist)
    end if
end if

! Set the initial values of some parameters. The last column of SIM holds the optimal vertex of the
! current simplex, and the preceding N columns hold the displacements from the optimal vertex to the
! other vertices.  Further, SIMI holds the inverse of the matrix that is contained in the first N
! columns of SIM.
factor_alpha = QUART
factor_beta = 2.1E0_RP
factor_delta = 1.1E0_RP
factor_gamma = HALF
rho = rhobeg
cpen = ZERO

call initxfc(iprint, maxfun, ctol, ftarget, rho, x, nf, chist, conhist, conmat, cval, fhist, fval, sim, xhist, evaluated, subinfo)
call initfilt(conmat, ctol, cval, fval, sim, evaluated, nfilt, cfilt, confilt, ffilt, xfilt)

if (subinfo == NAN_X .or. subinfo == NAN_INF_F .or. subinfo == FTARGET_ACHIEVED .or. subinfo == MAXFUN_REACHED) then
    info = subinfo
    ! Return the best calculated values of the variables.
    ! N.B. SELECTX and FINDPOLE choose X by different standards. One cannot replace the other.
    cpen = min(1.0E8_RP, HUGENUM)
    kopt = selectx(ffilt(1:nfilt), cfilt(1:nfilt), cpen, ctol)
    x = xfilt(:, kopt)
    f = ffilt(kopt)
    constr = confilt(:, kopt)
    cstrv = cfilt(kopt)
    !close (16)
    return
end if

! SIMI is the inverse of SIM(:, 1:N)
simi = inv(sim(:, 1:n), 'ltri')
! If we arrive here, the objective and constraints must have been evaluated at SIM(:, I) for all I.
evaluated = .true.

! Normally, each trust-region iteration takes one function evaluation. The following setting
! essentially imposes no constraint on the maximal number of trust-region iterations.
maxtr = 10 * maxfun
! MAXTR is unlikely to be reached, but we define the following default value for INFO for safety.
info = MAXTR_REACHED

! Begin the iterative procedure.
! After solving a trust-region subproblem, COBYLA uses 3 boolean variables to control the work flow.
! SHORTD - Is the trust-region trial step too short to invoke a function evaluation?
! IMPROVE_GEO - Will we improve the model after the trust-region iteration? If yes, a geometry step
! will be taken, corresponding to the Branch (Delta) in the COBYLA paper.
! REDUCE_RHO - Will we reduce rho after the trust-region iteration?
! COBYLA never sets IMPROVE_GEO and REDUCE_RHO to TRUE simultaneously.
do tr = 1, maxtr
    ! Before the trust-region step, call UPDATEPOLE so that SIM(:, N + 1) is the optimal vertex.
    call updatepole(cpen, evaluated, conmat, cval, fval, sim, simi, subinfo)
    if (subinfo == DAMAGING_ROUNDING) then
        info = subinfo
        exit
    end if

    ! Does the current interpolation set has good geometry? It affects IMPROVE_GEO and REDUCE_RHO.
    good_geo = goodgeo(factor_alpha, factor_beta, rho, sim, simi)

    ! Calculate the linear approximations to the objective and constraint functions, placing minus
    ! the objective function gradient after the constraint gradients in the array A.
    ! N.B.:
    ! 1. When __USE_INTRINSIC_ALGEBRA__ = 1, the following code may not produce the same result
    ! as Powell's, because the intrinsic MATMUL behaves differently from a naive triple loop in
    ! finite-precision arithmetic.
    ! 2. TRSTLP accesses A mostly by columns, so it is not more reasonable to save A^T instead of A.
    A(:, 1:m) = transpose(matprod(conmat(:, 1:n) - spread(conmat(:, n + 1), dim=2, ncopies=n), simi))
    A(:, m + 1) = matprod(fval(n + 1) - fval(1:n), simi)

    ! Exit if A contains NaN. Otherwise, TRSTLP may encounter memory errors or infinite loops.
    ! HOW EXACTLY?????
    !----------------------------------------------------------------------------------------------!
    ! POSSIBLE IMPROVEMENT: INSTEAD OF EXITING, SKIP A TRUST-REGION STEP AND PERFORM A GEOMETRY ONE!
    !----------------------------------------------------------------------------------------------!
    if (any(is_nan(A))) then
        info = NAN_MODEL
        exit
    end if

    ! Theoretically (but not numerically), the last entry of B does not affect the result of TRSTLP.
    b = [-conmat(:, n + 1), -fval(n + 1)]
    ! Calculate the trust-region trial step D.
    d = trstlp(A, b, rho)

    ! Is the trust-region trial step short?
    shortd = (inprod(d, d) < QUART * rho * rho)

    if (.not. shortd) then
        ! Predict the change to F (PREREF) and to the constraint violation (PREREC) due to D.
        preref = inprod(d, A(:, m + 1))
        prerec = cval(n + 1) - maxval([-matprod(d, A(:, 1:m)) - conmat(:, n + 1), ZERO])

        ! Increase CPEN if necessary and branch back if this change alters the optimal vertex.
        ! Otherwise, PREREM will be set to the predicted reductions in the merit function.
        ! See the discussions around equation (9) of the COBYLA paper.
        barmu = -preref / prerec   ! PREREF + BARMU * PREREC = 0
        !!!!!!!!!!!!!!! Is it possible that PREREC <= 0????????????? It seems yes.
        if (prerec > ZERO .and. cpen < 1.5E0_RP * barmu) then
            cpen = min(TWO * barmu, HUGENUM)
            if (findpole(cpen, evaluated, cval, fval) <= n) then
                cycle
            end if
        end if

        prerem = preref + cpen * prerec   ! Is it positive????

        x = sim(:, n + 1) + d
        if (any(is_nan(x))) then
            f = sum(x) ! Set F to NaN.
            constr = f  ! Set CONSTR to NaN.
        else
            call calcfc(n, m, x, f, constr)  ! Evaluate F and CONSTR.
        end if
        if (any(is_nan(constr))) then
            cstrv = sum(constr)  ! Set CSTRV to NaN.
        else
            cstrv = maxval([-constr, ZERO])  ! Constraint violation for constraints CONSTR(X) >= 0.
        end if
        nf = nf + 1_IK
        ! Save X, F, CONSTR, CSTRV into the history.
        call savehist(nf, constr, cstrv, f, x, chist, conhist, fhist, xhist)
        ! Save X, F, CONSTR, CSTRV into the filter.
        call savefilt(constr, cstrv, ctol, f, x, nfilt, cfilt, confilt, ffilt, xfilt)
        ! Check whether to exit.
        if (any(is_nan(x))) then
            info = NAN_X
            exit
        end if
        if (is_nan(f) .or. is_posinf(f) .or. is_nan(cstrv) .or. is_posinf(cstrv)) then
            info = NAN_INF_F
            exit
        end if
        if (f <= ftarget .and. cstrv <= ctol) then
            info = FTARGET_ACHIEVED
            exit
        end if
        if (nf >= maxfun) then
            info = MAXFUN_REACHED
            exit
        end if

        ! Begin the operations that decide whether X should replace one of the vertices of the
        ! current simplex, the change being mandatory if ACTREM is positive.
        actrem = (fval(n + 1) + cpen * cval(n + 1)) - (f + cpen * cstrv)
        if (cpen <= ZERO .and. abs(f - fval(n + 1)) <= ZERO) then
            prerem = prerec   ! Is it positive?????
            actrem = cval(n + 1) - cstrv
        end if

        ! Set JDROP to the index of the vertex that is to be replaced by X.
        ! N.B.: COBYLA never sets JDROP = N + 1.
        jdrop = setdrop_tr(actrem, d, factor_alpha, factor_delta, rho, sim, simi)

        ! When JDROP=0, the algorithm decides not to include X into the simplex.
        if (jdrop > 0) then
            ! Revise the simplex by updating the elements of SIM, SIMI, FVAL, CONMAT, and CVAL.
            sim(:, jdrop) = d
            simi_jdrop = simi(jdrop, :) / inprod(simi(jdrop, :), d)
            simi = simi - outprod(matprod(simi, d), simi_jdrop)
            simi(jdrop, :) = simi_jdrop
            fval(jdrop) = f
            conmat(:, jdrop) = constr
            cval(jdrop) = cstrv
        end if

    end if

    ! Should we take a geometry step to improve the geometry of the interpolation set?
    ! N.B.: THEORETICALLY, JDROP > 0 when ACTREM > 0, and hence the definition of BAD_TRSTEP is
    ! mathematically equivalent to (SHORTD .OR. ACTREM <= ZERO .OR. ACTREM < TENTH * PREREM);
    ! however, JDROP may turn out 0 due to NaN even if ACTREM > 0. See SETDRTOP_TR for details.
    bad_trstep = (shortd .or. actrem <= ZERO .or. actrem < TENTH * prerem .or. jdrop == 0)
    improve_geo = bad_trstep .and. .not. good_geo

    ! Should we revise RHO (and CPEN)?
    reduce_rho = bad_trstep .and. good_geo

    if (improve_geo) then
        ! Before the geometry step, call UPDATEPOLE so that SIM(:, N + 1) is the optimal vertex.
        call updatepole(cpen, evaluated, conmat, cval, fval, sim, simi, subinfo)
        if (subinfo == DAMAGING_ROUNDING) then
            info = subinfo
            exit
        end if

        ! If the current interpolation set has good geometry, then we skip the geometry step.
        ! The code has a small difference from the original COBYLA code here: If the current geometry
        ! is good, then we will continue with a new trust-region iteration; at the beginning of the
        ! iteration, CPEN may be updated, which may alter the pole point SIM(:, N + 1) by UPDATEPOLE;
        ! the quality of the interpolation point depends on SIM(:, N + 1), meaning that the same
        ! interpolation set may have good or bad geometry with respect to different "poles"; if the
        ! geometry turns out bad with the new pole, the original COBYLA code will take a geometry
        ! step, but the code here will NOT do it but continue to take a trust-region step.
        ! The argument is this: even if the geometry step is not skipped at the first place, the
        ! geometry may turn out bad again after the pole is altered due to an update to CPEN; should
        ! we take another geometry step in that case? If no, why should we do it here? Indeed, this
        ! distinction makes no practical difference for CUTEst problems with at most 100 variables
        ! and 5000 constraints, while the algorithm framework is simplified.
        if (.not. goodgeo(factor_alpha, factor_beta, rho, sim, simi)) then
            ! Decide a vertex to drop from the simplex. It will be replaced by SIM(:, N + 1) + D to
            ! improve acceptability of the simplex. See equations (15) and (16) of the COBYLA paper.
            ! N.B.: COBYLA never sets JDROP = N + 1.
            jdrop = setdrop_geo(factor_alpha, factor_beta, rho, sim, simi)

            ! If JDROP = 0 (probably due to NaN in SIM or SIMI), then we exit. Without this, memory
            ! error may occur as JDROP will be used as an index of arrays.
            if (jdrop == 0) then
                info = DAMAGING_ROUNDING
                exit
            end if

            ! Calculate the geometry step D.
            d = geostep(jdrop, cpen, conmat, cval, fval, factor_gamma, rho, simi)

            x = sim(:, n + 1) + d
            if (any(is_nan(x))) then
                f = sum(x) ! Set F to NaN.
                constr = f  ! Set CONSTR to NaN.
            else
                call calcfc(n, m, x, f, constr)  ! Evaluate F and CONSTR.
            end if
            if (any(is_nan(constr))) then
                cstrv = sum(constr)  ! Set CSTRV to NaN.
            else
                cstrv = maxval([-constr, ZERO])
            end if
            nf = nf + 1_IK
            ! Save X, F, CONSTR, CSTRV into the history.
            call savehist(nf, constr, cstrv, f, x, chist, conhist, fhist, xhist)
            ! Save X, F, CONSTR, CSTRV into the filter.
            call savefilt(constr, cstrv, ctol, f, x, nfilt, cfilt, confilt, ffilt, xfilt)
            ! Check whether to exit.
            if (any(is_nan(x))) then
                info = NAN_X
                exit
            end if
            if (is_nan(f) .or. is_posinf(f) .or. is_nan(cstrv) .or. is_posinf(cstrv)) then
                info = NAN_INF_F
                exit
            end if
            if (f <= ftarget .and. cstrv <= ctol) then
                info = FTARGET_ACHIEVED
                exit
            end if
            if (nf >= maxfun) then
                info = MAXFUN_REACHED
                exit
            end if

            ! Revise the simplex by updating the elements of SIM, SIMI, FVAL, CONMAT, and CVAL.
            sim(:, jdrop) = d
            simi_jdrop = simi(jdrop, :) / inprod(simi(jdrop, :), d)
            simi = simi - outprod(matprod(simi, d), simi_jdrop)
            simi(jdrop, :) = simi_jdrop
            fval(jdrop) = f
            conmat(:, jdrop) = constr
            cval(jdrop) = cstrv
        end if
    end if

    if (reduce_rho) then  ! Update RHO and CPEN.
        if (rho <= rhoend) then
            info = SMALL_TR_RADIUS
            exit
        end if
        ! See equation (11) in Section 3 of the COBYLA paper for the update of RHO.
        rho = HALF * rho
        if (rho <= 1.5E0_RP * rhoend) then
            rho = rhoend
        end if
        ! See equations (12)--(13) in Section 3 of the COBYLA paper for the update of CPEN.
        ! If the original CPEN = 0, then the updated CPEN is also 0.
        cmin = minval(conmat, dim=2)
        cmax = maxval(conmat, dim=2)
        if (any(cmin < HALF * cmax)) then
            denom = minval(max(cmax, ZERO) - cmin, mask=(cmin < HALF * cmax))
            cpen = min(cpen, (maxval(fval) - minval(fval)) / denom)
        else
            cpen = ZERO
        end if
    end if
end do

! Return the best calculated values of the variables.
! N.B. SELECTX and FINDPOLE choose X by different standards. One cannot replace the other.
cpen = max(cpen, min(1.0E8_RP, HUGENUM))
kopt = selectx(ffilt(1:nfilt), cfilt(1:nfilt), cpen, ctol)
x = xfilt(:, kopt)
f = ffilt(kopt)
constr = confilt(:, kopt)
cstrv = cfilt(kopt)

!close (16)

end subroutine cobylb


end module cobylb_mod

! TODO:
! 1. evalcfc
! 2. checkexit
! 3. update, absorbing updatepole
! 4. Do the same for initialize
! 5. Do the same for NEWUOA
