      subroutine qalt(gq, hq, pq, fval, smat, zmat, n, npt, kopt, idz)
      ! QALT calculates the alternative model, namely the model that
      ! minimizes the F-norm of the Hessian subject to the interpolation
      ! conditions. 
      ! Note that SMAT = BMAT(:, 1:NPT)

      use consts_mod, only : RP, IK, ZERO
      use lina_mod
      implicit none

      integer(IK), intent(in) :: n, npt, kopt, idz
      real(RP), intent(in) :: fval(npt), smat(n, npt), zmat(npt,npt-n-1)
      real(RP), intent(out) :: gq(n), hq(n, n), pq(npt)

      real(RP) :: vlag(npt), vz(npt - n - 1)


      vlag = fval - fval(kopt)
      gq = matmul(smat, vlag)
      hq = ZERO
      vz = matmul(vlag, zmat)
      vz(1 : idz - 1) = - vz(1 : idz - 1)
      pq = matmul(zmat, vz)

      return

      end subroutine qalt
