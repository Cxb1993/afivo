program test_mg
  use m_afivo_2d
  use m_mg2d

  implicit none

  integer, parameter :: dp           = kind(0.0d0)
  integer, parameter :: box_size     = 8
  integer, parameter :: n_boxes_base = 3
  integer, parameter :: i_phi = 1, i_tmp = 2
  integer, parameter :: i_rhs = 3, i_res = 4

  type(a2_t)         :: tree
  integer            :: i, id, n_changes
  integer            :: ix_list(2, n_boxes_base)
  integer            :: nb_list(4, n_boxes_base)
  integer            :: n_boxes_max  = 20*1000
  integer            :: n_lvls_max   = 20
  real(dp)           :: dr
  character(len=40)  :: fname, var_names(4)
  type(mg2_t)        :: mg

  var_names(i_phi) = "phi"
  var_names(i_tmp) = "tmp"
  var_names(i_rhs) = "rhs"
  var_names(i_res) = "res"

  dr = 4.0_dp / box_size

  ! Initialize tree
  call a2_init(tree, n_lvls_max, n_boxes_max, box_size, n_var_cell=4, &
       n_var_face=0, dr = dr, r_min = [0.0_dp, 0.0_dp])

  id = 1
  ix_list(:, id) = [1,1]         ! Set index of boxnn
  nb_list(:, id) = -1            ! Dirichlet zero -> -1
  nb_list(a2_nb_hx, id) = 2

  id = 2
  ix_list(:, id) = [2,1]         ! Set index of boxnn
  nb_list(:, id) = -1            ! Dirichlet zero -> -1
  nb_list(a2_nb_lx, id) = 1

  id = 3
  ix_list(:, id) = [2,2]         ! Set index of boxnn
  nb_list(:, id) = -1            ! Dirichlet zero -> -1
  nb_list(a2_nb_ly, id) = 2

  call a2_set_base(tree, ix_list, nb_list)

  do i = 1, 20
     call a2_adjust_refinement(tree, ref_func_init, n_changes)
     if (n_changes == 0) exit
  end do

  ! Set rhs and initial guess for phi
  call a2_loop_box(tree, set_init_cond)

  ! Set the multigrid options
  call mg2d_set(mg, i_phi, i_tmp, i_rhs, i_res, 2, 2, 2, &
       sides_bc, a2_corners_extrap, mg2d_lpl_box, mg2d_gsrb_lpl_box)

  ! Create a "subtree" with coarser levels than tree
  ! call mg2d_create_subtree(tree)

  ! Restrict from children recursively
  call mg2d_restrict_trees(tree, i_rhs, mg)
  call mg2d_restrict_trees(tree, i_phi, mg)

  !$omp parallel
  do i = 1, 100
     ! call mg2d_fas_vcycle(tree, mg, tree%n_lvls)
     call mg2d_fas_fmg(tree, mg)
     !$omp single
     ! write(fname, "(A,I0,A)") "test_mg_", i, ".vtu"
     ! call a2_write_tree(tree, trim(fname), var_names, i, 0.0_dp)
     !$omp end single
  end do
  !$omp end parallel

  ! write(fname, "(A,I0,A)") "test_mg_", 1, ".vtu"
  ! call a2_write_tree(tree, trim(fname), var_names, 1, 0.0_dp)

  print *, "max_id", tree%max_id
  print *, "n_cells", tree%max_id * tree%n_cell**2

  call a2_destroy(tree)

contains

  integer function ref_func_init(box)
    type(box2_t), intent(in) :: box
    if (box%lvl < 6 .or. &
         (box%lvl < 8 .and. (norm2(a2_r_center(box)-2) < 0.75_dp))) then
       ref_func_init = a5_do_ref
    else
       ref_func_init = a5_rm_ref
    end if
  end function ref_func_init

  subroutine set_init_cond(box)
    type(box2_t), intent(inout) :: box
    integer                     :: i, j, nc
    real(dp)                    :: xy(2)

    nc = box%n_cell
    box%cc(:, :, i_phi) = 0

    do j = 1, nc
       do i = 1, nc
          xy = a2_r_cc(box, [i,j])
          box%cc(i, j, i_rhs) = exp(-sum((xy - 2)**2))
       end do
    end do
  end subroutine set_init_cond

  subroutine sides_bc(boxes, id, nb, iv)
    type(box2_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, nb, iv
    integer                     :: nc
    real(dp)                    :: dr

    nc = boxes(id)%n_cell

    if (boxes(id)%neighbors(nb) == -1) then
       select case (nb)
       case (a2_nb_lx)
          ! Dirichlet zero
          boxes(id)%cc(0, 1:nc, iv) = -boxes(id)%cc(1, 1:nc, iv)
       case (a2_nb_hx)
          ! Dirichlet zero
          boxes(id)%cc(nc+1, 1:nc, iv) = -boxes(id)%cc(nc, 1:nc, iv)
       case (a2_nb_ly)
          ! Dirichlet zero
          boxes(id)%cc(1:nc, 0, iv) = -boxes(id)%cc(1:nc, 1, iv)
       case (a2_nb_hy)
          ! Neumann zero
          boxes(id)%cc(1:nc, nc+1, iv) = -boxes(id)%cc(1:nc, nc, iv)
       end select
    end if
  end subroutine sides_bc

end program test_mg