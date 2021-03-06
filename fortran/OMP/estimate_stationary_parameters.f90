subroutine estimate_stationary_parameters(K,T,Y0,method,optim_mode,lin_mode,options,mu_a,cov_a,mu,cov)
    !
    !   Copyright 2017, Viktor Reshiak, All rights reserved.    
    !    
    !   Purpose
    !   =======
    !   estimate parameters of the split-step method.
    !
    !
    !   Method
    !   ======
    !   Two-stage split-step Tau-leaping:
    !
    !   IN
    !   ==
    !   K         - number of time points
    !   T         - K-dimensional row vector of time points
    !   Y0        - num_species-dimensional column vector with initial data
    !
    !
    implicit none

    
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    ! dummy arguments

    integer(kind=4), intent(in)                             :: K
       real(kind=8), intent(in),  dimension(num_species)    :: Y0
       real(kind=8), intent(in),  dimension(K)              :: T
       real(kind=8), dimension(num_species,K)               :: mu_a, mu
       real(kind=8), dimension(num_species*num_species,K)   :: cov_a, cov
    character(len=100)                                      :: method
    character(len=3)                                        :: optim_mode, lin_mode
    type(solver_options), intent(inout)                     :: options

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!


    real(kind=8)                                         :: tau
    real(kind=8), dimension(num_reactions,num_species)   :: C
    real(kind=8), dimension(num_reactions)               :: d, a_buf
    real(kind=8), dimension(num_species,num_species)     :: eye_N
    real(kind=8), dimension(3*num_reactions)             :: params, params0

    real(kind=8), dimension(3*num_reactions)             :: lb, ub

    real(kind=8), dimension(num_species,num_reactions)   :: nu_real
    real(kind=8), dimension(num_species,num_species)     :: nu_C
    real(kind=8), dimension(num_species,num_species)     :: P1, P3, P4
    real(kind=8), dimension(num_reactions,num_reactions) :: diag_prop

    type(fsolve_info) :: fsolve_inf
    integer(kind=4)   :: i, j
       real(kind=8)   :: residual, residual1, residual2

    real(kind=8), parameter :: theta_0 = 1.0

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    tau = T(2) - T(1)
    
    eye_N = 0.d0
    forall(i=1:num_species) eye_N(i,i) = 1.d0

    nu_real   = nu
    diag_prop = 0.d0;

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    ! estimate true mean and true covariance
    mu_a(:,1)  = Y0    
    cov_a(:,1) = 0.d0 
    do i = 2,K
        call fsolve( num_species, num_species, fun, mu_a(:,i), X0=mu_a(:,i-1), info=fsolve_inf, Jac=Jac )
    enddo
    do i = 2,K
        C = propJacobian(mu_a(:,i))
        d = propensities(mu_a(:,i)) - matmul(C,mu_a(:,i))
        
        nu_C = matmul(nu,C)

        P1 = eye_N + tau * (1-theta_0) * nu_C
        call linsolve( num_species, num_species, eye_N-tau*theta_0*nu_C, P1 )
        P3 = 0.5d0 * eye_N - tau *    theta_0  * nu_C
        P4 = 0.5d0 * eye_N + tau * (1-theta_0) * nu_C

        a_buf = matmul(C,mu_a(:,i)) + d
        forall(j=1:num_reactions) diag_prop(j,j) = a_buf(j)
        cov_a(:,i) = matmul( kron(eye_N,P4)+kron(P4,eye_N), cov_a(:,i-1) ) + tau * matmul( kron(nu_real,nu_real), reshape(diag_prop,(/num_reactions**2/)) )
        call linsolve( num_species*num_species, 1, kron(eye_N,P3)+kron(P3,eye_N), cov_a(:,i) )
    enddo


    allocate( options%tht(num_reactions,K-1) )
    allocate( options%et1(num_reactions,K-1) )
    allocate( options%et2(num_reactions,K-1) )

    ! estimate parameters and mean/covariance of the linearized model
    mu(:,1)  = Y0    
    cov(:,1) = 0.d0 
    select case ( method )
        case ('ssTauLeap')
            ! bounds for constraint optimization
            lb(1:num_reactions)                 = 0.0d0
            ub(1:num_reactions)                 = 1.0d0
            lb(num_reactions+1:3*num_reactions) = 0.5d0
            ub(num_reactions+1:3*num_reactions) = 2.0d0

            ! intial guess for parameters
            a_buf = relaxRates(Y0) * tau
            params(1:num_reactions) = sqrt(2.d0/a_buf) - 1.d0/a_buf
            where ( a_buf < 2.0 ) params(1:num_reactions) = 0.633975 - 0.0566243 * a_buf
            params(num_reactions+1:3*num_reactions) = 1.0d0

            ! find optimal parameters
            do i = 2,K
                !select case ( lin_mode )
                    !case ( 'all' )
                    !    C = propJacobian(mu_a(:,i))
                    !    d = propensities(mu_a(:,i)) - matmul(C,mu_a(:,i))
                    !case ( 'end' )
                        C = propJacobian(mu_a(:,K))
                        d = propensities(mu_a(:,K)) - matmul(C,mu_a(:,K))
                !end select

                select case ( optim_mode )
                    case ( 'unc' )
                        residual = fminunc( 3*num_reactions, ss_residual, params )
                    case ( 'con' )
                        residual = fmincon( 3*num_reactions, ss_residual, params, lb=lb, ub=ub )
                end select

                options%tht(:,i-1) = params(1:num_reactions)
                options%et1(:,i-1) = params(num_reactions+1:2*num_reactions)
                options%et2(:,i-1) = params(2*num_reactions+1:3*num_reactions)
            enddo

            print*, ' '
            print*, 'Theta:'
            print*, params(1:num_reactions)
            print*, ' '
            print*, ' Eta1:'
            print*, params(num_reactions+1:2*num_reactions)
            print*, ' '
            print*, ' Eta2:'
            print*, params(2*num_reactions+1:3*num_reactions)
        case ('ThetaTauLeap')
            options%tht(:,i-1) = options%theta
            options%et1(:,i-1) = options%eta1
            options%et2(:,i-1) = options%eta2
            do i = 2,K
                C = propJacobian(mu_a(:,i))
                d = propensities(mu_a(:,i)) - matmul(C,mu_a(:,i))

                nu_C = matmul(nu,C)

                P1 = eye_N + tau * (1-options%theta) * nu_C
                call linsolve( num_species, num_species, eye_N-tau*options%theta*nu_C, P1 )

                a_buf = d + matmul( C, mu(:,i-1) ) 
                diag_prop = 0.d0
                forall(j=1:num_reactions) diag_prop(j,j) = a_buf(j)

                mu(:,i)  = matmul( P1,          mu(:,i-1)  )  +  tau * matmul(nu,d)
                cov(:,i) = matmul( kron(P1,P1), cov(:,i-1) )  +  tau * matmul( kron(nu_real,nu_real), reshape(diag_prop,(/num_reactions**2/)) )
            enddo
    end select

    print*, ' '
    print*, '      Final mean norm: ', sqrt(sum(mu_a(:,K)**2))
    print*, 'Final covariance norm: ', sqrt(sum(cov_a(:,K)**2))
    print*, ' '
    print*, '      Final mean residual: ', sqrt(sum((mu_a(:,K)-mu(:,K))**2))
    print*, 'Final covariance residual: ', sqrt(sum((cov_a(:,K)-cov(:,K))**2))

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    contains    
    subroutine fun(dim_f,dim_X,X,f)
        integer,      intent(in)                     :: dim_f, dim_X
        real(kind=8), intent(in),  dimension(dim_X ) :: X
        real(kind=8), intent(out), dimension(dim_f)  :: f

        f = X - mu_a(:,i-1) - matmul( nu, propensities(X) * tau )
    end subroutine fun
    subroutine Jac(dim_f,dim_X,X,J)
        integer,      intent(in)                          :: dim_f, dim_X
        real(kind=8), intent(in),  dimension(dim_X)       :: X
        real(kind=8), intent(out), dimension(dim_f,dim_X) :: J

        J = eye_N - tau * matmul( nu, propJacobian(X) )
    end subroutine Jac

  
    function ss_residual(dim_X,X) result(f)
        integer,      intent(in)                    :: dim_X
        real(kind=8), intent(in), dimension(dim_X ) :: X
        real(kind=8)                                :: f

        real(kind=8), dimension(num_reactions)                   :: tht, et1, et2
        real(kind=8), dimension(num_species,num_reactions)       :: nu_buf

        real(kind=8), dimension(num_species,num_species)         :: R1, R3, R3_R1
        real(kind=8), dimension(num_species)                     :: r2, r4

        real(kind=8), dimension(num_species**2,num_reactions**2) :: kron_R3_nu
        real(kind=8), dimension(num_species**2,num_species**2)   :: kron_R3_R1
        real(kind=8), dimension(num_reactions)                   :: C_r2
        real(kind=8), dimension(num_reactions,num_reactions)     :: diag_r2

        real(kind=8), dimension(num_species)                     :: mu_ref
        real(kind=8), dimension(num_species*num_species)         :: cov_ref

        integer :: j

        !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        tht = X(1:dim_X/3)
        et1 = X(dim_X/3+1:2*dim_X/3)
        et2 = X(2*dim_X/3+1:dim_X)

        forall(j=1:num_reactions) nu_buf(:,j) = nu(:,j) * (1-et1(j)) * (1-tht(j))
        R1 = eye_N + tau * matmul(nu_buf,C)

        forall(j=1:num_reactions) nu_buf(:,j) = nu(:,j) * (1-tht(j))
        r2 = matmul(nu_buf,d)

        forall(j=1:num_reactions) nu_buf(:,j) = nu(:,j) * (1-et2(j)) * tht(j)
        R3 = eye_N + tau * matmul(nu_buf,C)

        forall(j=1:num_reactions) nu_buf(:,j) = nu(:,j) * tht(j)
        r4 = matmul(nu_buf,d)

        forall(j=1:num_reactions) nu_buf(:,j) = nu(:,j) * et1(j) * (1-tht(j))
        call linsolve( num_species, num_species, eye_N-tau*matmul(nu_buf,C), R1 )
        call linsolve( num_species, 1,           eye_N-tau*matmul(nu_buf,C), r2 )

        forall(j=1:num_reactions) nu_buf(:,j) = nu(:,j) * et2(j) * tht(j)
        call linsolve( num_species, num_species, eye_N-tau*matmul(nu_buf,C), R3 )
        call linsolve( num_species, 1,           eye_N-tau*matmul(nu_buf,C), r4 )


        R3_R1      = matmul(R3,R1)
        kron_R3_nu = matmul( kron( R3, R3 ), kron( nu_real, nu_real ) )
        kron_R3_R1 = kron( R3_R1, R3_R1 )

        mu(:,i) = matmul(R3,r2) + r4
        call linsolve( num_species, 1, eye_N - R3_R1, mu(:,i) )
        mu(:,i) = tau * mu(:,i)

        C_r2 = d + matmul( C, mu(:,i) ) 
        diag_r2 = 0.d0
        forall(j=1:num_reactions) diag_r2(j,j) = C_r2(j)
        cov(:,i) = matmul( kron_R3_nu, reshape(diag_r2,(/num_reactions**2/)) )
        call linsolve( num_species*num_species, 1, kron(eye_N,eye_N) - matmul(kron(R3,R3),kron(R1,R1)), cov(:,i) )
        cov(:,i) = tau * cov(:,i)

        mu_ref = matmul(nu_real,d)
        call linsolve(num_species,1,matmul(nu_real,C),mu_ref)

        C_r2 = d + matmul( C, mu_a(:,K) ) 
        diag_r2 = 0.d0
        forall(j=1:num_reactions) diag_r2(j,j) = C_r2(j)
        cov_ref = matmul( kron(nu_real,nu_real), reshape(diag_r2,(/num_reactions**2/)) )
        call linsolve(num_species*num_species,1,kron(matmul(nu,C),eye_N)+kron(eye_N,matmul(nu,C)),cov_ref)
        cov_ref = - cov_ref

        f = sum((mu(:,i)-mu_ref)**2) + sum((cov(:,i)-cov_ref)**2)
        print*, d
    end

end subroutine estimate_stationary_parameters