module m_afivo

  implicit none
  private

  integer, parameter :: dp = kind(0.0d0)

  ! Boundary conditions
  integer, parameter :: a5_bnd_refinement = -1

  ! Each box contains a tag, for which the following bits are set:
  integer, parameter :: a5_bit_in_use = 1
  integer, parameter :: a5_bit_fresh = 2

  type box_2d_t
     integer               :: lvl
     integer               :: tag
     integer               :: ix(2)
     integer               :: parent
     integer               :: children(4)
     integer               :: neighbors(4)
     real(dp), allocatable :: cc(:, :, :)
     real(dp), allocatable :: fx(:, :, :)
     real(dp), allocatable :: fy(:, :, :)
  end type box_2d_t

  type level_2d_t
     integer, allocatable        :: ids(:)
     type(morton_t), allocatable :: mortons(:)
  end type level_2d_t

  type a5_2d_t
     real(dp)                    :: r_min(2)
     real(dp)                    :: dr(2, a5_max_levels)
     type(level_2d_t)            :: levels(a5_max_levels)
     integer                     :: n_levels
     integer                     :: n_points
     integer                     :: n_cc
     integer                     :: n_fx
     integer                     :: n_fy
     integer                     :: n_boxes
     type(box_2d_t), allocatable :: boxes(:)
     procedure(ref_f), pointer   :: ref_func => null()
  end type a5_2d_t

contains

  subroutine a5_2d_init(self, dr_coarse, n_boxes_max, ref_func, &
       n_points, n_cc, n_fx, n_fy)
    type(a5_2d_t)        :: self
    real(dp), intent(in) :: dr_coarse(2)
    integer, intent(in)  :: n_boxes_max
    integer, intent(in)  :: n_points, n_cc, n_fx, n_fy
    procedure(ref_f)     :: ref_func
    integer              :: lvl, ix

    do lvl = 1, a5_max_levels
       self%dr(:, lvl) = dr_coarse * 0.5_dp**(lvl-1)
    end do

    self%n_levels = 0
    self%n_points = n_points
    self%n_cc     = n_cc
    self%n_fx     = n_fx
    self%n_fy     = n_fy
    self%n_boxes  = 0
    self%ref_func => ref_func
    allocate(self%boxes(n_boxes_max))
    allocate(self%mortons(n_boxes_max))
  end subroutine a5_2d_init

  subroutine a5_tidy_storage(self, new_size)
    type(a5_2d_t) :: ! TODO
  end subroutine a5_tidy_storage

  subroutine a5_set_neighbors_2d(self)
    type(a5_2d_t), intent(inout) :: self

    do lvl = 1, self%n_levels
       n_boxes = size(self%levels(lvl)%box_ids)
       do i = 1, n_boxes
          ! For each "fresh" box, find possible neighbors
          id = self%levels(lvl)%box_ids(i)
          if (btest(self%boxes(id)%tag, a5_bit_fresh)) then
             call set_nbs_2d(self, id)
          end if
       end do
    end do
  end subroutine a5_set_neighbors_2d

  subroutine set_nbs_2d(self, id)
    type(a5_2d_t), intent(inout) :: self
    integer, intent(in)          :: id
    integer                      :: d, i

    do d = 1, 2                 ! Dimension
       do i = 1, 2              ! Lower / higher
          if (self%boxes(id)%neighbors(d, i) == 0) then
          nb_id = get_nb_id_2d(self, id, d, i)

          if (nb_id /= -1) then
             self%boxes(id)%neighbors(d, i) = nb_id
             j = reverse_nb(i)
             self%boxes(nb_id)%neighbors(d, j) = id
          else
             self%boxes(id)%neighbors(i) = a5_bnd_refinement
          end if
       end if
    end do
  end subroutine set_nbs_2d

  ! Swap 1 -> 2, 2 -> 1
  elemental function reverse_ix(ix)
    integer, intent(in) :: ix
    reverse_ix = ieor(nb_num, 3)
  end function reverse_ix

  ! Odd to 1, even to 2
  elemental function get_child_ix(ix)
    integer, intent(in) :: ix
    get_child_ix = 2 - iand(ix, 1)
  end function get_child_ix

  ! Get neighbor_id of id, in direction d, i = 1 means lower neighbor, i = 2
  ! means higher neighbor.
  function get_nb_id_2d(boxes, id, d, i) result(nb_id)
    type(box_2d_t), intent(in) :: boxes(:)
    integer, intent(in)        :: id, d, i
    integer                    :: p_id, c_ix(2)

    p_id = boxes(ix)%parent
    c_ix = get_child_ix(boxes(id)%ix)

    ! Check if neighbor is in same direction as current id is (1 = lower ix, 2 =
    ! higher ix). If so, use neighbor of parent
    if (btest(c_ix(d), 0) .eqv. btest(i, 0)) &
         p_id = boxes(p_id)%neighbors(d, i)

    ! The child ix of the neighbor is swapped in direction d
    c_ix(d) = reverse(c_ix(d))
    nb_id = boxes(p_id)%child(c_ix(1), c_ix(2))
  end function get_nb_id_2d

  ! After boxes have been added to level 1, this stores them as a "level"
  subroutine a5_set_base_2d(self)
    use mrgrnk
    type(a5_2d_t), intent(inout) :: self
    integer                      :: n_boxes
    integer, allocatable         :: ixs(:)

    self%n_levels = 1
    n_boxes       = self%n_boxes

    allocate(self%levels(1)%box_ids(n_boxes))
    call mrgrnk(self%mortons(1:n_boxes), ixs)
    self%levels(1)%box_ids(:) = ixs(:)
  end subroutine a5_set_base_2d

  ! This can be used to add level 1 boxes
  subroutine a5_add_base_box_2d(self, ix, nbs)
    type(a5_2d_t), intent(inout) :: self
    integer, intent(in)          :: ix(2)
    integer, intent(in)          :: nbs(2, 2)
    type(a5_box_2d)              :: new_box
    integer                      :: i, id

    new_box%ix        = ix
    new_box%lvl       = 1
    new_box%parent    = 0
    new_box%children  = 0
    new_box%neighbors = nbs
    
    ! Set "in_use" and "fresh" tag
    new_box%tag       = 0
    new_box%tag       = ibset(new_box%tag, a5_bit_in_use)
    new_box%tag       = ibset(new_box%tag, a5_bit_fresh)

    ! Add box to storage
    id             = self%n_boxes + 1
    self%n_boxes   = id
    self%boxes(id) = new_box
    call alloc_storage_2d(self, id)

    ! Set morton number for box
    call morton_from_ix2(ix, self%mortons(id))
  end subroutine a5_add_base_box_2d

  subroutine a5_destroy_box(box)
    type(box_2d_t), intent(inout) :: box
    if (associated(box%children)) stop "still have children"
    deallocate(vars)
  end subroutine a5_destroy_box

  subroutine a5_get_child_array(bxa, bxa_children)
    type(box_array_t), intent(in) :: bxa
    type(box_array_t), intent(out) :: bxa_children

    ...
  end subroutine a5_get_child_array

  subroutine a5_prolong()

  end subroutine a5_prolong

  subroutine a5_restrict()

  end subroutine a5_restrict

  function find_box_2d(lvl_2d, morton) result(id)
    type(level_2d_t), intent(in) :: lvl_2d
    type(morton_t), intent(in)   :: morton
    integer                      :: id, ix

    ix = bsearch(lvl_2d%mortons, morton)
    if (ix /= -1) then
       id = lvl_2d%ids(ix)
    else
       id = -1
    end if
  end function find_box_2d

  function bsearch(list, val) result(ix)
    integer(kind=morton_k), intent(in) :: list(:)
    integer(kind=morton_k), intent(in) :: val
    integer                            :: ix, i_min, i_max, i_middle

    i_min = 1
    i_max = size(list)

    do while (i_min < i_max)
       i_middle = i_min + (i_max - i_min) / 2

       if (val <= list(i_middle)) then
          i_max = i_middle
       else
          i_min = i_middle + 1
       end if
    end do

    ix = i_min
    if (val > list(ix)) ix = -1
  end function bsearch

end module m_afivo