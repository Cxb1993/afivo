! AFiVO code for Xd simulations. The following replacements take place on this code:
! 1. $ D -> 2 or 3 (dimension of code)
! 2. preprocess file with cpp
! 3. cat -s (merge multiple blank lines)
module m_afivo_$D
  use m_afivo_constants
  use m_afivo_hdr_$Dd

  implicit none
  public

contains

  ! Initialize a $Dd tree type
  subroutine a$D_init(tree, max_lvl, n_boxes, n_cell, n_var_cell, n_var_face, &
       dr, r_min)
    type(a$D_t), intent(out) :: tree       ! The tree to initialize
    integer, intent(in)     :: max_lvl    ! Maximum number of levels
    integer, intent(in)     :: n_boxes    ! Allocate initial storage for n_boxes
    integer, intent(in)     :: n_cell     ! Boxes have n_cell^dim cells
    integer, intent(in)     :: n_var_cell ! Number of cell-centered variables
    integer, intent(in)     :: n_var_face ! Number of face-centered variables
    real(dp), intent(in)    :: dr         ! spacing of a cell
    real(dp), intent(in)    :: r_min(2)   ! Lower left coordinate of box 1,1
    integer                 :: lvl

    if (n_cell < 2)       stop "a$D_init: n_cell should be >= 2"
    if (btest(n_cell, 0)) stop "a$D_init: n_cell should be even"
    if (n_var_cell <= 0)  stop "a$D_init: n_var_cell should be > 0"
    if (n_boxes <= 0)     stop "a$D_init: n_boxes should be > 0"

    allocate(tree%boxes(n_boxes))
    allocate(tree%lvls(max_lvl+1))

    ! up to max_lvl+1 to add dummies that are always of size zero
    do lvl = 1, max_lvl+1
       allocate(tree%lvls(lvl)%ids(0))
       allocate(tree%lvls(lvl)%leaves(0))
       allocate(tree%lvls(lvl)%parents(0))
    end do

    tree%boxes(:)%tag = 0
    tree%n_cell       = n_cell
    tree%n_var_cell   = n_var_cell
    tree%n_var_face   = n_var_face
    tree%r_base       = r_min
    tree%dr_base      = dr
    tree%max_lvl      = max_lvl
    tree%max_id       = 0
    tree%n_lvls       = 0
  end subroutine a$D_init

  ! Since we use no pointers, you can also just let a tree get out of scope
  subroutine a$D_destroy(tree)
    type(a$D_t), intent(inout) :: tree
    integer                   :: lvl

    deallocate(tree%boxes)
    do lvl = 1, tree%max_lvl
       deallocate(tree%lvls(lvl)%ids)
       deallocate(tree%lvls(lvl)%leaves)
       deallocate(tree%lvls(lvl)%parents)
    end do
    tree%max_id = 0
  end subroutine a$D_destroy

  ! Call procedure for each box in tree
  subroutine a$D_loop_box(tree, my_procedure)
    type(a$D_t), intent(inout) :: tree
    procedure(a$D_subr)        :: my_procedure
    integer                   :: lvl, i, id

    do lvl = 1, tree%max_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call my_procedure(tree%boxes(id))
       end do
       !$omp end do nowait
    end do
    !$omp barrier
  end subroutine a$D_loop_box

  ! Call procedure for each box in tree, with argument rarg
  subroutine a$D_loop_box_arg(tree, my_procedure, rarg)
    type(a$D_t), intent(inout) :: tree
    procedure(a$D_subr_arg)    :: my_procedure
    real(dp), intent(in)      :: rarg(:)
    integer                   :: lvl, i, id

    do lvl = 1, tree%max_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call my_procedure(tree%boxes(id), rarg)
       end do
       !$omp end do nowait
    end do
    !$omp barrier
  end subroutine a$D_loop_box_arg

  ! Call procedure for each id in tree, giving the list of boxes
  subroutine a$D_loop_boxes(tree, my_procedure)
    type(a$D_t), intent(inout) :: tree
    procedure(a$D_subr_boxes)  :: my_procedure
    integer                   :: lvl, i, id

    do lvl = 1, tree%max_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call my_procedure(tree%boxes, id)
       end do
       !$omp end do nowait
    end do
    !$omp barrier
  end subroutine a$D_loop_boxes

  ! Call procedure for each id in tree, giving the list of boxes
  subroutine a$D_loop_boxes_arg(tree, my_procedure, rarg)
    type(a$D_t), intent(inout)    :: tree
    procedure(a$D_subr_boxes_arg) :: my_procedure
    real(dp), intent(in)         :: rarg(:)
    integer                      :: lvl, i, id

    do lvl = 1, tree%max_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call my_procedure(tree%boxes, id, rarg)
       end do
       !$omp end do nowait
    end do
    !$omp barrier
  end subroutine a$D_loop_boxes_arg

  ! Clear the bit from all the tags in the tree
  subroutine a$D_clear_tagbit(tree, bit)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: bit
    tree%boxes(1:tree%max_id)%tag = ibclr(tree%boxes(1:tree%max_id)%tag, bit)
  end subroutine a$D_clear_tagbit

  ! Resize and reorder the list of boxes.
  subroutine a$D_tidy_up(tree, max_frac_used, goal_frac_used, &
       n_clean_min, only_reorder)
    use m_morton
    type(a$D_t), intent(inout)      :: tree
    real(dp), intent(in)           :: max_frac_used, goal_frac_used
    integer, intent(in)            :: n_clean_min
    logical, intent(in)            :: only_reorder
    real(dp)                       :: frac_in_use
    integer                        :: n, lvl, id, old_size, new_size, n_clean
    integer                        :: max_id, n_used, n_stored, n_used_lvl
    integer, allocatable           :: ixs_sort(:), ixs_map(:)
    type(box$D_t), allocatable      :: boxes_cpy(:)
    integer(morton_k), allocatable :: mortons(:)

    !$omp single
    if (goal_frac_used > max_frac_used) &
         stop "a$D_tidy_up: need goal_frac_used < max_frac_used"
    if (max_frac_used > 1.0_dp) stop "a$D_tidy_up: need max_frac_used < 1"
    if (n_clean_min < 1)        stop "a$D_tidy_up: need n_clean_min > 0"

    max_id      = tree%max_id
    n_used      = count(btest(tree%boxes(1:max_id)%tag, a5_bit_in_use))
    old_size    = size(tree%boxes)
    frac_in_use = n_used / real(old_size, dp)
    n_clean     = nint((goal_frac_used - frac_in_use) * old_size)
    new_size    = old_size

    if (.not. only_reorder) then
       if (frac_in_use > max_frac_used .or. &
            (frac_in_use < goal_frac_used .and. &
            n_clean > n_clean_min)) then
          new_size = max(1, nint(n_used/goal_frac_used))
       end if
    end if

    if (new_size /= old_size .or. only_reorder) then
       print *, "a$D_tidy_up:", old_size, new_size, only_reorder

       if (only_reorder) then
          allocate(boxes_cpy(n_used))  ! Need just enough space
       else
          allocate(boxes_cpy(new_size))
       end if

       allocate(ixs_map(0:max_id))
       ixs_map(0)       = 0
       n_stored         = 0

       do lvl = 1, tree%n_lvls
          n_used_lvl = size(tree%lvls(lvl)%ids)
          allocate(mortons(n_used_lvl))
          allocate(ixs_sort(n_used_lvl))

          do n = 1, n_used_lvl
             id = tree%lvls(lvl)%ids(n)
             ! Note the -1, since our indices start at 1
             mortons(n) = morton_from_ix2(tree%boxes(id)%ix-1)
          end do

          call morton_rank(mortons, ixs_sort)
          tree%lvls(lvl)%ids = tree%lvls(lvl)%ids(ixs_sort)

          do n = 1, n_used_lvl
             id = tree%lvls(lvl)%ids(n)
             boxes_cpy(n_stored + n) = tree%boxes(id)
             ixs_map(tree%lvls(lvl)%ids(n)) = n_stored + n
          end do

          tree%lvls(lvl)%ids = [(n_stored+n, n=1,n_used_lvl)]
          call set_leaves_parents(boxes_cpy, tree%lvls(lvl))
          n_stored = n_stored + n_used_lvl
          deallocate(mortons)
          deallocate(ixs_sort)
       end do

       ! Update id's to new indices
       do n = 1, n_used
          boxes_cpy(n)%parent = ixs_map(boxes_cpy(n)%parent)
          boxes_cpy(n)%children = ixs_map(boxes_cpy(n)%children)
          where (boxes_cpy(n)%neighbors > a5_no_box)
             boxes_cpy(n)%neighbors = ixs_map(boxes_cpy(n)%neighbors)
          end where
       end do

       if (only_reorder) then
          tree%boxes(1:n_used) = boxes_cpy ! Copy ordered data
          do n = n_used+1, max_id
             call dealloc_box(tree%boxes(n)) ! Remove unused data
             tree%boxes(n)%tag = 0
          end do
       else
          call move_alloc(boxes_cpy, tree%boxes)
          tree%boxes(n_used+1:)%tag = 0
       end if

       tree%max_id = n_used
    end if
    !$omp end single
  end subroutine a$D_tidy_up

  ! Create a list of leaves and a list of parents for level
  subroutine set_leaves_parents(boxes, level)
    type(box$D_t), intent(in)    :: boxes(:)
    type(lvl$D_t), intent(inout) :: level
    integer                     :: i, id, i_leaf, i_parent

    i_leaf   = 0
    i_parent = 0
    do i = 1, size(level%ids)
       id = level%ids(i)
       if (a$D_has_children(boxes(id))) then
          i_parent                = i_parent + 1
          level%parents(i_parent) = id
       else
          i_leaf               = i_leaf + 1
          level%leaves(i_leaf) = id
       end if
    end do
  end subroutine set_leaves_parents

  ! Allocate the data storage for a box
  subroutine alloc_box(box, n_cell, n_cc, n_fc)
    type(box$D_t), intent(inout) :: box
    integer, intent(in)         :: n_cell, n_cc, n_fc

    allocate(box%cc(0:n_cell+1, 0:n_cell+1, n_cc))
    allocate(box%fx(n_cell+1,   n_cell,     n_fc))
    allocate(box%fy(n_cell,     n_cell+1,   n_fc))
  end subroutine alloc_box

  ! Deallocate the data storage for a box
  subroutine dealloc_box(box)
    type(box$D_t), intent(inout) :: box
    deallocate(box%cc)
    deallocate(box%fx)
    deallocate(box%fy)
  end subroutine dealloc_box

  ! Set the neighbors of id (using their parent)
  subroutine set_nbs_$Dd(boxes, id)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id
    integer                     :: nb, nb_id

    do nb = 1, a$D_num_neighbors
       if (boxes(id)%neighbors(nb) == a5_no_box) then
          nb_id = find_nb_$Dd(boxes, id, nb)
          if (nb_id > a5_no_box) then
             boxes(id)%neighbors(nb) = nb_id
             boxes(nb_id)%neighbors(a$D_nb_rev(nb)) = id
          end if
       end if
    end do
  end subroutine set_nbs_$Dd

  ! Compute the child index of ix
  integer function a$D_ix_to_cix(ix)
    integer, intent(in) :: ix($D)
    ! Second index odd: -2, first ix odd: -1
#if $D == 2
    a$D_ix_to_cix = 4 - 2 * iand(ix(2), 1) - iand(ix(1), 1)
#elif $D == 3
    a3_ix_to_cix = 8 - 4 * iand(ix(3), 1) - 2 * iand(ix(2), 1) - iand(ix(1), 1)
#endif
  end function a$D_ix_to_cix

  ! Get neighbor nb of id, through its parent
  function find_nb_$Dd(boxes, id, nb) result(nb_id)
    type(box$D_t), intent(in) :: boxes(:)
    integer, intent(in)      :: id, nb
    integer                  :: nb_id, p_id, c_ix, d, old_pid

    p_id = boxes(id)%parent
    old_pid = p_id
    c_ix = a$D_ix_to_cix(boxes(id)%ix)
    d = a$D_nb_dim(nb)

    ! Check if neighbor is in same direction as ix is (low/high). If so,
    ! use neighbor of parent
    if (a$D_ch_low(c_ix, d) .eqv. a$D_nb_low(nb)) &
         p_id = boxes(p_id)%neighbors(nb)

    ! The child ix of the neighbor is reversed in direction d
    nb_id = boxes(p_id)%children(a$D_ch_rev(c_ix, d))
  end function find_nb_$Dd

  ! Create the base level of the tree, ix_list(:, id) stores the index of box
  ! id, nb_list(:, id) stores the neighbors of box id
  subroutine a$D_set_base(tree, ix_list, nb_list)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: ix_list(:, :)
    integer, intent(inout)    :: nb_list(:, :)
    integer                   :: n_boxes, i, id, nb, nb_id

    if (any(ix_list < 1)) stop "a$D_set_base: need all ix_list > 0"

    ! Neighbors only have to be specified from one side, mirror them
    n_boxes = size(ix_list, 2)
    do i = 1, n_boxes
       do nb = 1, a$D_num_neighbors
          nb_id = nb_list(nb, i)
          if (nb_id > a5_no_box) nb_list(a$D_nb_rev(nb), nb_id) = i
       end do
    end do

    if (any(nb_list == a5_no_box)) stop "a$D_set_base: unresolved neighbors"

    deallocate(tree%lvls(1)%ids)
    deallocate(tree%lvls(1)%leaves)
    allocate(tree%lvls(1)%ids(n_boxes))
    allocate(tree%lvls(1)%leaves(n_boxes))

    call a$D_get_free_ids(tree, tree%lvls(1)%ids)
    tree%n_lvls = 1
    tree%lvls(1)%leaves = tree%lvls(1)%ids

    do i = 1, n_boxes
       id                       = tree%lvls(1)%ids(i)
       tree%boxes(id)%ix        = ix_list(:, i)
       tree%boxes(id)%lvl       = 1
       tree%boxes(id)%parent    = 0
       tree%boxes(id)%children  = 0
       tree%boxes(id)%neighbors = nb_list(:, i)
       tree%boxes(id)%n_cell    = tree%n_cell
       tree%boxes(id)%dr        = tree%dr_base
       tree%boxes(id)%r_min     = tree%r_base + &
            (ix_list(:, i) - 1) * tree%dr_base * tree%n_cell
       tree%boxes(id)%tag       = ibset(0, a5_bit_in_use)

       call alloc_box(tree%boxes(id), tree%n_cell, &
            tree%n_var_cell, tree%n_var_face)
    end do
  end subroutine a$D_set_base

  ! Resize the box storage to new_size
  subroutine a$D_resize_box_storage(tree, new_size)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: new_size
    type(box$D_t), allocatable :: boxes_cpy(:)

    allocate(boxes_cpy(new_size))
    boxes_cpy(1:tree%max_id)      = tree%boxes(1:tree%max_id)
    boxes_cpy(tree%max_id+1:)%tag = 0 ! empty tag
    call move_alloc(boxes_cpy, tree%boxes)
  end subroutine a$D_resize_box_storage

  ! On input, tree should be balanced. On output, tree is still balanced, and
  ! its refinement is updated (with at most one level per call).
  ! Sets bit: a5_bit_new_children
  subroutine a$D_adjust_refinement(tree, ref_func, n_changes)
    type(a$D_t), intent(inout)      :: tree
    procedure(a$D_to_int_f)         :: ref_func
    integer, intent(out), optional :: n_changes
    integer                        :: lvl, id, i, c_ids(a$D_num_children), i_c
    integer                        :: max_id_prev, max_id_req
    integer                        :: n_leaves, n_parents
    integer, allocatable           :: ref_flags(:)

    !$omp single
    max_id_prev = tree%max_id
    allocate(ref_flags(max_id_prev))

    ! Clear refinement tags from previous calls
    call a$D_clear_tagbit(tree, a5_bit_new_children)

    ! Set refinement values for all boxes
    call a$D_set_ref_flags(tree%lvls, tree%n_lvls, tree%max_lvl, tree%boxes, &
         ref_flags, ref_func)

    if (present(n_changes)) n_changes = count(ref_flags /= a5_kp_ref)

    ! Check whether there is enough free space, otherwise extend the list
    max_id_req = max_id_prev + a$D_num_children * count(ref_flags == a5_do_ref)
    if (max_id_req > size(tree%boxes)) then
       print *, "Resizing box storage for refinement", max_id_req
       call a$D_resize_box_storage(tree, max_id_req)
    end if

    do lvl = 1, tree%max_lvl-1
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)

          if (id > max_id_prev) then
             cycle              ! This is a newly added box
          else if (ref_flags(id) == a5_do_ref) then
             ! Add children. First need to get num_children free id's
             call a$D_get_free_ids(tree, c_ids)
             call a$D_add_children(tree%boxes, id, c_ids)
          else if (ref_flags(id) == a5_rm_children) then
             ! Remove children
             call a$D_remove_children(tree%boxes, id)
          end if
       end do

       ! Set next level ids to children of this level
       deallocate(tree%lvls(lvl+1)%ids)
       call set_child_ids(tree%lvls(lvl)%ids, &
            tree%lvls(lvl+1)%ids, tree%boxes)

       ! Update connectivity of children
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          if (a$D_has_children(tree%boxes(id))) then
             do i_c = 1, a$D_num_children
                call set_nbs_$Dd(tree%boxes, tree%boxes(id)%children(i_c))
             end do
          end if
       end do

       if (size(tree%lvls(lvl+1)%ids) == 0) exit
    end do

    tree%n_lvls = lvl

    ! Update leaves and parents
    do lvl = 1, tree%n_lvls
       n_parents = size(tree%lvls(lvl+1)%ids)/a$D_num_children
       n_leaves = size(tree%lvls(lvl)%ids) - n_parents

       deallocate(tree%lvls(lvl)%leaves)
       deallocate(tree%lvls(lvl)%parents)
       allocate(tree%lvls(lvl)%leaves(n_leaves))
       allocate(tree%lvls(lvl)%parents(n_parents))
       call set_leaves_parents(tree%boxes, tree%lvls(lvl))
    end do
    !$omp end single
  end subroutine a$D_adjust_refinement

  ! Get free ids to store new boxes in
  subroutine a$D_get_free_ids(tree, ids)
    type(a$D_t), intent(inout) :: tree
    integer, intent(out)      :: ids(:)
    integer                   :: i, max_id_prev, n_ids

    n_ids = size(ids)
    !$omp critical
    max_id_prev = tree%max_id
    tree%max_id = tree%max_id + n_ids
    !$omp end critical

    ids = [(max_id_prev + i, i=1,n_ids)]
  end subroutine a$D_get_free_ids

  ! Given the refinement function, return consistent refinement flags
  subroutine a$D_set_ref_flags(lvls, n_lvls, max_lvl, boxes, ref_flags, ref_func)
    type(lvl$D_t), intent(in)    :: lvls(:)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: n_lvls, max_lvl
    integer, intent(inout)      :: ref_flags(:)
    procedure(a$D_to_int_f)      :: ref_func
    integer                     :: lvl, i, id, c_ids(a$D_num_children)
    integer                     :: nb, p_id, nb_id, p_nb_id

    ref_flags(:) = a5_kp_ref      ! Used indices are overwritten

    ! Set refinement flags for all boxes using ref_func
    do lvl = 1, n_lvls
       do i = 1, size(lvls(lvl)%ids)
          id            = lvls(lvl)%ids(i)
          ref_flags(id) = ref_func(boxes(id))
       end do
    end do

    ! Cannot derefine lvl 1
    do i = 1, size(lvls(1)%ids)
       id = lvls(1)%ids(i)
       if (ref_flags(id) == a5_rm_ref) ref_flags(id) = a5_kp_ref
    end do

    ! Cannot refine beyond max level
    do i = 1, size(lvls(max_lvl)%ids)
       id = lvls(max_lvl)%ids(i)
       if (ref_flags(id) == a5_do_ref) ref_flags(id) = a5_kp_ref
    end do

    ! Ensure 2-1 balance.
    do lvl = n_lvls, 2, -1
       do i = 1, size(lvls(lvl)%leaves) ! We only check leaf boxes
          id = lvls(lvl)%leaves(i)

          if (ref_flags(id) == a5_do_ref) then
             ! Ensure we will have the necessary neighbors
             do nb = 1, a$D_num_neighbors
                nb_id = boxes(id)%neighbors(nb)
                if (nb_id == a5_no_box) then
                   ! Mark the parent containing neighbor for refinement
                   p_id = boxes(id)%parent
                   p_nb_id = boxes(p_id)%neighbors(nb)
                   ref_flags(p_nb_id) = a5_do_ref
                end if
             end do
          else if (ref_flags(id) == a5_rm_ref) then
             ! Ensure we do not remove a required neighbor
             do nb = 1, a$D_num_neighbors
                nb_id = boxes(id)%neighbors(nb)
                if (nb_id > a5_no_box) then
                   if (a$D_has_children(boxes(nb_id)) .or. &
                        ref_flags(nb_id) == a5_do_ref) then
                      ref_flags(id) = a5_kp_ref
                   end if
                end if
             end do
          end if
       end do
    end do

    ! Make the (de)refinement flags consistent for blocks with children.
    do lvl = n_lvls-1, 1, -1
       do i = 1, size(lvls(lvl)%parents)
          id = lvls(lvl)%parents(i)

          ! Can only remove children if they are all marked for
          ! derefinement, and the box itself not for refinement.
          c_ids = boxes(id)%children
          if (all(ref_flags(c_ids) == a5_rm_ref) .and. &
               ref_flags(id) /= a5_do_ref) then
             ref_flags(id) = a5_rm_children
          else
             ref_flags(id) = a5_kp_ref
             where (ref_flags(c_ids) == a5_rm_ref)
                ref_flags(c_ids) = a5_kp_ref
             end where
          end if
       end do
    end do

  end subroutine a$D_set_ref_flags

  ! Remove the children of box id
  subroutine a$D_remove_children(boxes, id)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id
    integer                     :: ic, c_id, nb_id, nb_rev, nb

    do ic = 1, a$D_num_children
       c_id            = boxes(id)%children(ic)
       boxes(c_id)%tag = 0      ! clear tag

       do nb = 1, a$D_num_neighbors             ! Remove from neighbors
          nb_id = boxes(c_id)%neighbors(nb)
          if (nb_id > a5_no_box) then
             nb_rev = a$D_nb_rev(nb)
             boxes(nb_id)%neighbors(nb_rev) = a5_no_box
          end if
       end do
    end do

    boxes(id)%children = a5_no_box
  end subroutine a$D_remove_children

  ! Add children to box id, using the indices in c_ids
  subroutine a$D_add_children(boxes, id, c_ids)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, c_ids(a$D_num_children)
    integer                     :: i, ch_nb(2), c_id, c_ix_base(2)

    boxes(id)%children = c_ids
    c_ix_base          = 2 * boxes(id)%ix - 1
    boxes(id)%tag      = ibset(boxes(id)%tag, a5_bit_new_children)

    do i = 1, a$D_num_children
       c_id                  = c_ids(i)
       boxes(c_id)%ix        = c_ix_base + a$D_ch_dix(:,i)
       boxes(c_id)%lvl       = boxes(id)%lvl+1
       boxes(c_id)%parent    = id
       boxes(c_id)%children  = a5_no_box
       boxes(c_id)%neighbors = a5_no_box
       boxes(c_id)%n_cell    = boxes(id)%n_cell
       boxes(c_id)%dr        = 0.5_dp * boxes(id)%dr
       boxes(c_id)%r_min     = boxes(id)%r_min + 0.5_dp * boxes(id)%dr * &
            a$D_ch_dix(:,i) * boxes(id)%n_cell
       boxes(c_id)%tag       = ibset(0, a5_bit_in_use)

       call alloc_box(boxes(c_id), boxes(id)%n_cell, &
            size(boxes(id)%cc, 3), size(boxes(id)%fx, 3))
    end do

    ! Set boundary conditions at children
    do i = 1, a$D_num_children
       if (boxes(id)%neighbors(i) < a5_no_box) then
          ch_nb = c_ids(a$D_ch_adj_nb(:, i)) ! Neighboring children
          boxes(ch_nb)%neighbors(i) = boxes(id)%neighbors(i)
       end if
    end do
  end subroutine a$D_add_children

  ! Create a list c_ids of all the children of p_ids
  subroutine set_child_ids(p_ids, c_ids, boxes)
    integer, intent(in)                 :: p_ids(:)
    integer, allocatable, intent(inout) :: c_ids(:)
    type(box$D_t), intent(in)            :: boxes(:)
    integer                             :: i, ip, i_c, n_children

    ! Count a$D_num_children times the number of refined parent blocks
    n_children = a$D_num_children * count(a$D_has_children(boxes(p_ids)))
    allocate(c_ids(n_children))

    i_c = 0
    do i = 1, size(p_ids)
       ip = p_ids(i)
       if (a$D_has_children(boxes(ip))) then
          c_ids(i_c+1:i_c+a$D_num_children) = boxes(ip)%children
          i_c = i_c + a$D_num_children
       end if
    end do
  end subroutine set_child_ids

  elemental logical function a$D_has_children(box)
    type(box$D_t), intent(in) :: box
    a$D_has_children = (box%children(1) /= a5_no_box)
  end function a$D_has_children

  ! Return minimum dr that is used in the tree
  pure function a$D_min_dr(tree) result(dr)
    type(a$D_t), intent(in) :: tree
    real(dp)               :: dr($D)
    dr = tree%dr_base * 0.5_dp**(tree%n_lvls-1)
  end function a$D_min_dr

  ! Return the coordinate of the center of a box
  pure function a$D_r_center(box) result(r_center)
    type(box$D_t), intent(in) :: box
    real(dp)                 :: r_center($D)
    r_center = box%r_min + 0.5_dp * box%n_cell * box%dr
  end function a$D_r_center

  ! Location of cell center with index cc_ix
  pure function a$D_r_cc(box, cc_ix) result(r)
    type(box$D_t), intent(in) :: box
    integer, intent(in)      :: cc_ix($D)
    real(dp)                 :: r($D)
    r = box%r_min + (cc_ix-0.5_dp) * box%dr
  end function a$D_r_cc

  ! Location of node with index nd_ix
  pure function a$D_r_node(box, nd_ix) result(r)
    type(box$D_t), intent(in) :: box
    integer, intent(in)      :: nd_ix($D)
    real(dp)                 :: r($D)
    r = box%r_min + (nd_ix-1) * box%dr
  end function a$D_r_node

  ! True -> 1, false -> 0
  elemental integer function l2i(my_bool)
    logical, intent(in) :: my_bool
    if (my_bool) then
       l2i = 1
    else
       l2i = 0
    end if
  end function l2i

  ! Add cc(:,:, iv_from) to box%cc(:,:, iv_to)
  subroutine a$D_box_add_cc(box, iv_from, iv_to)
    type(box$D_t), intent(inout) :: box
    integer, intent(in)         :: iv_from, iv_to
    box%cc(:,:, iv_to) = box%cc(:,:, iv_to) + box%cc(:,:, iv_from)
  end subroutine a$D_box_add_cc

  ! Subtract cc(:,:, iv_from) from box%cc(:,:, iv_to)
  subroutine a$D_box_sub_cc(box, iv_from, iv_to)
    type(box$D_t), intent(inout) :: box
    integer, intent(in)         :: iv_from, iv_to
    box%cc(:,:, iv_to) = box%cc(:,:, iv_to) - box%cc(:,:, iv_from)
  end subroutine a$D_box_sub_cc

  ! Copy cc(:,:, iv_from) to box%cc(:,:, iv_to)
  subroutine a$D_box_copy_cc(box, iv_from, iv_to)
    type(box$D_t), intent(inout) :: box
    integer, intent(in)         :: iv_from, iv_to
    box%cc(:,:, iv_to) = box%cc(:,:, iv_from)
  end subroutine a$D_box_copy_cc

  ! Copy cc(:,:, iv_from) to box%cc(:,:, iv_to) for all ids
  subroutine a$D_boxes_copy_cc(boxes, ids, iv_from, iv_to)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: ids(:), iv_from, iv_to
    integer                     :: i

    !$omp do
    do i = 1, size(ids)
       call a$D_box_copy_cc(boxes(ids(i)), iv_from, iv_to)
    end do
    !$omp end do
  end subroutine a$D_boxes_copy_cc

  ! Copy cc(:,:, iv_from) to box%cc(:,:, iv_to) for full tree
  subroutine a$D_tree_copy_cc(tree, iv_from, iv_to)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: iv_from, iv_to
    integer                   :: lvl

    do lvl = 1, tree%n_lvls
       call a$D_boxes_copy_cc(tree%boxes, tree%lvls(lvl)%ids, iv_from, iv_to)
    end do
  end subroutine a$D_tree_copy_cc

  ! Bilinear prolongation to children. Uses ghost cells and corners.
#if $D == 2
  subroutine a2_prolong1_from(boxes, id, iv, fill_gc)
    type(box2_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, iv
    logical, intent(in)         :: fill_gc
    real(dp), parameter         :: f1=1/16.0_dp, f3=3/16.0_dp, f9=9/16.0_dp
    integer                     :: nc, i_c, c_id, ix_offset(2)
    integer                     :: i, j, i_c1, i_c2, j_c1, j_c2

    nc = boxes(id)%n_cell
    do i_c = 1, a2_num_children
       c_id = boxes(id)%children(i_c)

       ! Offset of child w.r.t. parent
       ix_offset = a2_ch_dix(:, i_c) * ishft(nc, -1)

       ! In these loops, we calculate the closest coarse index (_c1), and the
       ! one-but-closest (_c2). The fine cell lies in between.
       do j = 1-l2i(fill_gc), nc+l2i(fill_gc)
          j_c1 = ix_offset(2) + ishft(j+1, -1) ! (j+1)/2
          j_c2 = j_c1 + 1 - 2 * iand(j, 1)          ! even: +1, odd: -1
          do i = 1-l2i(fill_gc), nc+l2i(fill_gc)
             i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2
             i_c2 = i_c1 + 1 - 2 * iand(i, 1)          ! even: +1, odd: -1

             boxes(c_id)%cc(i, j, iv) = &
                  f9 * boxes(id)%cc(i_c1, j_c1, iv) + &
                  f3 * boxes(id)%cc(i_c2, j_c1, iv) + &
                  f3 * boxes(id)%cc(i_c1, j_c2, iv) + &
                  f1 * boxes(id)%cc(i_c2, j_c2, iv)
          end do
       end do
    end do
  end subroutine a2_prolong1_from
#elif $D == 3
  subroutine a3_prolong1_from(boxes, id, ivs, fill_gc)
    type(box3_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, ivs(:)
    logical, intent(in)         :: fill_gc
    real(dp), parameter         :: f1=1/64.0_dp, f3=3/64.0_dp
    real(dp), parameter         :: f9=9/64.0_dp, f27=27/64.0_dp
    integer                     :: v, iv, nc, i_c, c_id, ix_offset(3)
    integer                     :: i, j, k, i_c1, i_c2, j_c1, j_c2, k_c1, k_c2

    nc = boxes(id)%n_cell
    do i_c = 1, 8
       c_id = boxes(id)%children(i_c)

       ! Offset of child w.r.t. parent
       ix_offset = a3_ch_dix(:, i_c) * ishft(nc, -1)

       ! In these loops, we calculate the closest coarse index (_c1), and the
       ! one-but-closest (_c2). The fine cell lies in between.
       do v = 1, size(ivs)
          iv = ivs(v)
          do k = 1-l2i(fill_gc), nc+l2i(fill_gc)
             k_c1 = ix_offset(3) + ishft(k+1, -1) ! (k+1)/2
             k_c2 = k_c1 + 1 - 2 * iand(k, 1)     ! even: +1, odd: -1
             do j = 1-l2i(fill_gc), nc+l2i(fill_gc)
                j_c1 = ix_offset(2) + ishft(j+1, -1) ! (j+1)/2
                j_c2 = j_c1 + 1 - 2 * iand(j, 1)          ! even: +1, odd: -1
                do i = 1-l2i(fill_gc), nc+l2i(fill_gc)
                   i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2
                   i_c2 = i_c1 + 1 - 2 * iand(i, 1)          ! even: +1, odd: -1

                   boxes(c_id)%cc(i, j, k, iv) = &
                        f27 * boxes(id)%cc(i_c1, j_c1, k_c1, iv) + &
                        f9 * boxes(id)%cc(i_c2, j_c1, k_c1, iv) + &
                        f9 * boxes(id)%cc(i_c1, j_c2, k_c1, iv) + &
                        f9 * boxes(id)%cc(i_c1, j_c1, k_c2, iv) + &
                        f3 * boxes(id)%cc(i_c1, j_c2, k_c2, iv) + &
                        f3 * boxes(id)%cc(i_c2, j_c1, k_c2, iv) + &
                        f3 * boxes(id)%cc(i_c2, j_c2, k_c1, iv) + &
                        f1 * boxes(id)%cc(i_c2, j_c2, k_c2, iv)
                end do
             end do
          end do
       end do
    end do
  end subroutine a3_prolong1_from
#endif

  ! Partial prolongation from parent using injection.
#if $D == 2
  subroutine a$D_prolong0_to(boxes, id, lo, hi, iv)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, lo($D), hi($D), iv
    integer                     :: nc, p_id, ix_offset($D)
    integer                     :: i, j, i_c1, j_c1

    nc        = boxes(id)%n_cell
    p_id      = boxes(id)%parent
    ! Offset of child w.r.t. parent
    ix_offset = (boxes(id)%ix - 2*boxes(p_id)%ix + 1) * ishft(nc, -1)

    do j = lo(2), hi(2)
       j_c1 = ix_offset(2) + ishft(j+1, -1) ! (j+1)/2
       do i = lo(1), hi(1)
          i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2
          boxes(id)%cc(i, j, iv) = boxes(p_id)%cc(i_c1, j_c1, iv)
       end do
    end do
  end subroutine a$D_prolong0_to
#elif $D == 3
  subroutine a3_prolong0_to(boxes, id, lo, hi, ivs)
    type(box3_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, lo(3), hi(3), ivs(:)
    integer                     :: v, iv, nc, p_id, ix_offset(3)
    integer                     :: i, j, k, i_c1, j_c1, k_c1

    nc        = boxes(id)%n_cell
    p_id      = boxes(id)%parent
    ! Offset of child w.r.t. parent
    ix_offset = (boxes(id)%ix - 2*boxes(p_id)%ix + 1) * ishft(nc, -1)

    do v = 1, size(ivs)
       iv = ivs(v)
       do k = lo(3), hi(3)
          k_c1 = ix_offset(3) + ishft(k+1, -1) ! (k+1)/2
          do j = lo(2), hi(2)
             j_c1 = ix_offset(2) + ishft(j+1, -1) ! (j+1)/2
             do i = lo(1), hi(1)
                i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2
                boxes(id)%cc(i, j, k, iv) = boxes(p_id)%cc(i_c1, j_c1, k_c1, iv)
             end do
          end do
       end do
    end do
  end subroutine a3_prolong0_to
#endif

  ! Partial bilinear prolongation from parent.
#if $D == 2
  subroutine a$D_prolong1_to(boxes, id, lo, hi, iv)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, lo(2), hi(2), iv
    real(dp), parameter         :: f1=1/16.0_dp, f3=3/16.0_dp, f9=9/16.0_dp
    integer                     :: nc, p_id, ix_offset(2)
    integer                     :: i, j, i_c1, i_c2, j_c1, j_c2

    nc        = boxes(id)%n_cell
    p_id      = boxes(id)%parent
    ! Offset of child w.r.t. parent
    ix_offset = (boxes(id)%ix - 2 * boxes(p_id)%ix + 1) * ishft(nc, -1)

    ! In these loops, we calculate the closest coarse index (i_c1, j_c1), and
    ! the one-but-closest (i_c2, j_c2). The fine cell lies in between.
    do j = lo(2), hi(2)
       j_c1 = ix_offset(2) + ishft(j+1, -1) ! (j+1)/2
       j_c2 = j_c1 + 1 - 2 * iand(j, 1)          ! even: +1, odd: -1
       do i = lo(1), hi(1)
          i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2
          i_c2 = i_c1 + 1 - 2 * iand(i, 1)          ! even: +1, odd: -1
          boxes(id)%cc(i, j, iv) = &
               f9 * boxes(p_id)%cc(i_c1, j_c1, iv) + &
               f3 * boxes(p_id)%cc(i_c2, j_c1, iv) + &
               f3 * boxes(p_id)%cc(i_c1, j_c2, iv) + &
               f1 * boxes(p_id)%cc(i_c2, j_c2, iv)
       end do
    end do
  end subroutine a$D_prolong1_to
#elif $D == 3
  subroutine a3_prolong1_to(boxes, id, lo, hi, ivs)
    type(box3_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, lo(3), hi(3), ivs(:)
    real(dp), parameter         :: f1=1/64.0_dp, f3=3/64.0_dp
    real(dp), parameter         :: f9=9/64.0_dp, f27=27/64.0_dp
    integer                     :: v, iv, nc, p_id, ix_offset(3)
    integer                     :: i, j, k
    integer                     :: i_c1, i_c2, j_c1, j_c2, k_c1, k_c2

    nc        = boxes(id)%n_cell
    p_id      = boxes(id)%parent
    ! Offset of child w.r.t. parent
    ix_offset = (boxes(id)%ix - 2 * boxes(p_id)%ix + 1) * ishft(nc, -1)

    ! In these loops, we calculate the closest coarse index (i_c1, j_c1), and
    ! the one-but-closest (i_c2, j_c2). The fine cell lies in between.
    do v = 1, size(ivs)
       iv = ivs(v)
       do k = lo(3), hi(3)
          k_c1 = ix_offset(3) + ishft(k+1, -1) ! (k+1)/2
          k_c2 = k_c1 + 1 - 2 * iand(k, 1)     ! even: +1, odd: -1
          do j = lo(2), hi(2)
             j_c1 = ix_offset(2) + ishft(j+1, -1) ! (j+1)/2
             j_c2 = j_c1 + 1 - 2 * iand(j, 1)          ! even: +1, odd: -1
             do i = lo(1), hi(1)
                i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2
                i_c2 = i_c1 + 1 - 2 * iand(i, 1)          ! even: +1, odd: -1
                boxes(id)%cc(i, j, k, iv) = &
                     f27 * boxes(p_id)%cc(i_c1, j_c1, k_c1, iv) + &
                     f9 * boxes(p_id)%cc(i_c2, j_c1, k_c1, iv) + &
                     f9 * boxes(p_id)%cc(i_c1, j_c2, k_c1, iv) + &
                     f9 * boxes(p_id)%cc(i_c1, j_c1, k_c2, iv) + &
                     f3 * boxes(p_id)%cc(i_c1, j_c2, k_c2, iv) + &
                     f3 * boxes(p_id)%cc(i_c2, j_c1, k_c2, iv) + &
                     f3 * boxes(p_id)%cc(i_c2, j_c2, k_c1, iv) + &
                     f1 * boxes(p_id)%cc(i_c2, j_c2, k_c2, iv)
             end do
          end do
       end do
    end do
  end subroutine a3_prolong1_to
#endif

  ! Conservative restriction. a$D_num_children fine cells to one parent cell
  subroutine a$D_restrict_to_box(boxes, id, iv)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, iv
    integer                     :: nc, i_c, c_id, ix_offset($D)

    nc = boxes(id)%n_cell
    do i_c = 1, a$D_num_children
       c_id = boxes(id)%children(i_c)
       if (c_id == a5_no_box) cycle
       ! Offset of child w.r.t. parent
       ix_offset = a$D_ch_dix(:, i_c) * ishft(nc, -1)
       call a$D_restrict_box(boxes(c_id), boxes(id), ix_offset, iv)
    end do
  end subroutine a$D_restrict_to_box

  ! Restrict variables iv to parent boxes ids(:)
  subroutine a$D_restrict_to_boxes(boxes, ids, iv)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: ids(:), iv
    integer                     :: i

    !$omp do
    do i = 1, size(ids)
       call a$D_restrict_to_box(boxes, ids(i), iv)
    end do
    !$omp end do
  end subroutine a$D_restrict_to_boxes

  ! Restrict variables iv to all parent boxes
  subroutine a$D_restrict_tree(tree, iv)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: iv
    integer                   :: lvl

    do lvl = tree%max_lvl-1, 1, -1
       call a$D_restrict_to_boxes(tree%boxes, tree%lvls(lvl)%parents, iv)
    end do
  end subroutine a$D_restrict_tree

  ! Conservative restriction. a$D_num_children fine cells to one parent cell
#if $D == 2
  subroutine a2_restrict_box(box_c, box_p, ix_offset, iv)
    type(box2_t), intent(in)    :: box_c
    type(box2_t), intent(inout) :: box_p
    integer, intent(in)         :: ix_offset(2), iv
    integer                     :: nc, v, i, j, i_c1, j_c1

    nc = box_c%n_cell

    do j = 1, nc, 2
       j_c1 = ix_offset(2) + ishft(j+1, -1)  ! (j+1)/2
       do i = 1, nc, 2
          i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2

          box_p%cc(i_c1, j_c1, iv) = 0.25_dp * (&
               box_c%cc(i,   j,   iv) + &
               box_c%cc(i+1, j,   iv) + &
               box_c%cc(i,   j+1, iv) + &
               box_c%cc(i+1, j+1, iv) )
       end do
    end do
  end subroutine a2_restrict_box
#elif $D == 3
  subroutine a3_restrict_box(box_c, box_p, ix_offset, ivs)
    type(box3_t), intent(in)    :: box_c
    type(box3_t), intent(inout) :: box_p
    integer, intent(in)         :: ix_offset(3), ivs(:)
    integer                     :: nc, v, iv, i, j, k
    integer                     :: i_c1, j_c1, k_c1

    nc = box_c%n_cell

    do v = 1, size(ivs)
       iv = ivs(v)
       do k = 1, nc, 2
          k_c1 = ix_offset(3) + ishft(k+1, -1)  ! (k+1)/2
          do j = 1, nc, 2
             j_c1 = ix_offset(2) + ishft(j+1, -1)  ! (j+1)/2
             do i = 1, nc, 2
                i_c1 = ix_offset(1) + ishft(i+1, -1) ! (i+1)/2

                box_p%cc(i_c1, j_c1, k_c1, iv) = 0.125_dp * ( &
                     box_c%cc(i,   j,   k,   iv) + &
                     box_c%cc(i+1, j,   k,   iv) + &
                     box_c%cc(i,   j+1, k,   iv) + &
                     box_c%cc(i+1, j+1, k,   iv) + &
                     box_c%cc(i,   j,   k+1, iv) + &
                     box_c%cc(i+1, j,   k+1, iv) + &
                     box_c%cc(i,   j+1, k+1, iv) + &
                     box_c%cc(i+1, j+1, k+1, iv))
             end do
          end do
       end do
    end do
  end subroutine a3_restrict_box
#endif

  ! Fill ghost cells for variables iv on the sides of all boxes, using
  ! subr_no_nb on refinement boundaries and subr_bc on physical boundaries
  subroutine a$D_gc_sides(tree, iv, subr_no_nb, subr_bc)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: iv
    procedure(a$D_subr_gc)     :: subr_no_nb, subr_bc
    integer                   :: lvl, i, id

    do lvl = 1, tree%n_lvls
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call a$D_gc_box_sides(tree%boxes, id, iv, subr_no_nb, subr_bc)
       end do
       !$omp end do
    end do
  end subroutine a$D_gc_sides

  ! Fill ghost cells for variables iv on the sides of a boxes, using
  ! subr_no_nb on refinement boundaries and subr_bc on physical boundaries
  subroutine a$D_gc_box_sides(boxes, id, iv, subr_no_nb, subr_bc)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, iv
    procedure(a$D_subr_gc)       :: subr_no_nb, subr_bc
    integer                     :: nb

    do nb = 1, a$D_num_neighbors
       if (boxes(id)%neighbors(nb) > a5_no_box) then
          call a$D_gc_side_from_nb(boxes, id, nb, iv)
       else if (boxes(id)%neighbors(nb) == a5_no_box) then
          call subr_no_nb(boxes, id, nb, iv)
       else
          call subr_bc(boxes, id, nb, iv)
       end if
    end do
  end subroutine a$D_gc_box_sides

  ! Bilinear interpolation from parent to fill ghost cells on sides
#if $D == 2
  subroutine a2_sides_prolong1(boxes, id, nb, iv)
    type(box2_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, nb, iv
    integer                     :: nc

    nc = boxes(id)%n_cell

    select case (nb)
    case (a2_nb_lx)
       call a2_prolong1_to(boxes, id, [0, 1], [0, nc], iv)
    case (a2_nb_hx)
       call a2_prolong1_to(boxes, id, [nc+1, 1], [nc+1, nc], iv)
    case (a2_nb_ly)
       call a2_prolong1_to(boxes, id, [1, 0], [nc, 0], iv)
    case (a2_nb_hy)
       call a2_prolong1_to(boxes, id, [1, nc+1], [nc, nc+1], iv)
    end select
  end subroutine a2_sides_prolong1
#elif $D == 3
  subroutine a3_sides_prolong1(boxes, id, nb, ivs)
    type(box3_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, nb, ivs(:)
    integer                     :: nc

    nc = boxes(id)%n_cell

    select case (nb)
    case (a3_nb_lx)
       call a3_prolong1_to(boxes, id, [0, 1, 1], [0, nc, nc], ivs)
    case (a3_nb_hx)
       call a3_prolong1_to(boxes, id, [nc+1, 1, 1], [nc+1, nc, nc], ivs)
    case (a3_nb_ly)
       call a3_prolong1_to(boxes, id, [1, 0, 1], [nc, 0, nc], ivs)
    case (a3_nb_hy)
       call a3_prolong1_to(boxes, id, [1, nc+1, 1], [nc, nc+1, nc], ivs)
    case (a3_nb_lz)
       call a3_prolong1_to(boxes, id, [1, 1, 0], [nc, nc, 0], ivs)
    case (a3_nb_hz)
       call a3_prolong1_to(boxes, id, [1, 1, nc+1], [nc, nc, nc+1], ivs)
    end select
  end subroutine a3_sides_prolong1
#endif

  ! Special interpolation on sides which preserves diffusive fluxes
#if $D == 2
  subroutine a2_sides_extrap(boxes, id, nb, iv)
    type(box2_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, nb, iv
    integer                     :: nc

    nc = boxes(id)%n_cell

    select case (nb)
    case (a2_nb_lx)
       call a2_prolong0_to(boxes, id, [0, 1], [0, nc], iv)
       boxes(id)%cc(0, 1:nc, iv) = 0.5_dp * boxes(id)%cc(0, 1:nc, iv) &
            + 0.75_dp * boxes(id)%cc(1, 1:nc, iv) &
            - 0.25_dp * boxes(id)%cc(2, 1:nc, iv)
    case (a2_nb_hx)
       call a2_prolong0_to(boxes, id, [nc+1, 1], [nc+1, nc], iv)
       boxes(id)%cc(nc+1, 1:nc, iv) = 0.5_dp * boxes(id)%cc(nc+1, 1:nc, iv) &
            + 0.75_dp * boxes(id)%cc(nc, 1:nc, iv) &
            - 0.25_dp * boxes(id)%cc(nc-1, 1:nc, iv)
    case (a2_nb_ly)
       call a2_prolong0_to(boxes, id, [1, 0], [nc, 0], iv)
       boxes(id)%cc(1:nc, 0, iv) = 0.5_dp * boxes(id)%cc(1:nc, 0, iv) &
            + 0.75_dp * boxes(id)%cc(1:nc, 1, iv) &
            - 0.25_dp * boxes(id)%cc(1:nc, 2, iv)
    case (a2_nb_hy)
       call a2_prolong0_to(boxes, id, [1, nc+1], [nc, nc+1], iv)
       boxes(id)%cc(1:nc, nc+1, iv) = 0.5_dp * boxes(id)%cc(1:nc, nc+1, iv) &
            + 0.75_dp * boxes(id)%cc(1:nc, nc, iv) &
            - 0.25_dp * boxes(id)%cc(1:nc, nc-1, iv)
    end select
  end subroutine a2_sides_extrap
#elif $D == 3
  subroutine a3_sides_extrap(boxes, id, nb, ivs)
    type(box3_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, nb, ivs(:)
    integer                     :: nc

    nc = boxes(id)%n_cell

    select case (nb)
    case (a3_nb_lx)
       call a3_prolong0_to(boxes, id, [0, 1, 1], [0, nc, nc], ivs)
       boxes(id)%cc(0, 1:nc, 1:nc, ivs) = &
            0.5_dp * boxes(id)%cc(0, 1:nc, 1:nc, ivs) &
            + 0.75_dp * boxes(id)%cc(1, 1:nc, 1:nc, ivs) &
            - 0.25_dp * boxes(id)%cc(2, 1:nc, 1:nc, ivs)
    case (a3_nb_hx)
       call a3_prolong0_to(boxes, id, [nc+1, 1, 1], [nc+1, nc, nc], ivs)
       boxes(id)%cc(nc+1, 1:nc, 1:nc, ivs) = &
            0.5_dp * boxes(id)%cc(nc+1, 1:nc, 1:nc, ivs) &
            + 0.75_dp * boxes(id)%cc(nc, 1:nc, 1:nc, ivs) &
            - 0.25_dp * boxes(id)%cc(nc-1, 1:nc, 1:nc, ivs)
    case (a3_nb_ly)
       call a3_prolong0_to(boxes, id, [1, 0, 1], [nc, 0, nc], ivs)
       boxes(id)%cc(1:nc, 0, 1:nc, ivs) = &
            0.5_dp * boxes(id)%cc(1:nc, 0, 1:nc, ivs) &
            + 0.75_dp * boxes(id)%cc(1:nc, 1, 1:nc, ivs) &
            - 0.25_dp * boxes(id)%cc(1:nc, 2, 1:nc, ivs)
    case (a3_nb_hy)
       call a3_prolong0_to(boxes, id, [1, nc+1, 1], [nc, nc+1, nc], ivs)
       boxes(id)%cc(1:nc, nc+1, 1:nc, ivs) = &
            0.5_dp * boxes(id)%cc(1:nc, nc+1, 1:nc, ivs) &
            + 0.75_dp * boxes(id)%cc(1:nc, nc, 1:nc, ivs) &
            - 0.25_dp * boxes(id)%cc(1:nc, nc-1, 1:nc, ivs)
    case (a3_nb_lz)
       call a3_prolong0_to(boxes, id, [1, 1, 0], [nc, nc, 0], ivs)
       boxes(id)%cc(1:nc, 1:nc, 0, ivs) = &
            0.5_dp * boxes(id)%cc(1:nc, 1:nc, 0, ivs) &
            + 0.75_dp * boxes(id)%cc(1:nc, 1:nc, 1, ivs) &
            - 0.25_dp * boxes(id)%cc(1:nc, 1:nc, 2, ivs)
    case (a3_nb_hz)
       call a3_prolong0_to(boxes, id, [1, 1, nc+1], [nc, nc, nc+1], ivs)
       boxes(id)%cc(1:nc, 1:nc, nc+1, ivs) = &
            0.5_dp * boxes(id)%cc(1:nc, 1:nc, nc+1, ivs) &
            + 0.75_dp * boxes(id)%cc(1:nc, 1:nc, nc, ivs) &
            - 0.25_dp * boxes(id)%cc(1:nc, 1:nc, nc-1, ivs)
    end select
  end subroutine a3_sides_extrap
#endif

  ! Fill values on side from a neighbor
  subroutine a$D_gc_side_from_nb(boxes, id, nb, iv)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, nb, iv
    integer                     :: nc, nb_id

    nc    = boxes(id)%n_cell
    nb_id = boxes(id)%neighbors(nb)

    select case (nb)
#if $D == 2
    case (a2_nb_lx)
       boxes(id)%cc(0, 1:nc, iv)    = boxes(nb_id)%cc(nc, 1:nc, iv)
    case (a2_nb_hx)
       boxes(id)%cc(nc+1, 1:nc, iv) = boxes(nb_id)%cc(1, 1:nc, iv)
    case (a2_nb_ly)
       boxes(id)%cc(1:nc, 0, iv)    = boxes(nb_id)%cc(1:nc, nc, iv)
    case (a2_nb_hy)
       boxes(id)%cc(1:nc, nc+1, iv) = boxes(nb_id)%cc(1:nc, 1, iv)
#elif $D == 3
    case (a3_nb_lx)
       boxes(id)%cc(0, 1:nc, 1:nc, ivs)    = boxes(nb_id)%cc(nc, 1:nc, 1:nc, ivs)
    case (a3_nb_hx)
       boxes(id)%cc(nc+1, 1:nc, 1:nc, ivs) = boxes(nb_id)%cc(1, 1:nc, 1:nc, ivs)
    case (a3_nb_ly)
       boxes(id)%cc(1:nc, 0, 1:nc, ivs)    = boxes(nb_id)%cc(1:nc, nc, 1:nc, ivs)
    case (a3_nb_hy)
       boxes(id)%cc(1:nc, nc+1, 1:nc, ivs) = boxes(nb_id)%cc(1:nc, 1, 1:nc, ivs)
    case (a3_nb_lz)
       boxes(id)%cc(1:nc, 1:nc, 0, ivs)    = boxes(nb_id)%cc(1:nc, 1:nc, nc, ivs)
    case (a3_nb_hz)
       boxes(id)%cc(1:nc, 1:nc, nc+1, ivs) = boxes(nb_id)%cc(1:nc, 1:nc, 1, ivs)
#endif
    end select
  end subroutine a$D_gc_side_from_nb

  ! Fill ghost cells for variables iv on the corners of all boxes, using
  ! subr_no_nb on refinement boundaries and subr_bc on physical boundaries
  subroutine a$D_gc_corners(tree, iv, subr_no_nb, subr_bc)
    type(a$D_t), intent(inout) :: tree
    integer, intent(in)       :: iv
    procedure(a$D_subr_gc)     :: subr_no_nb, subr_bc
    integer                   :: lvl, i, id

    do lvl = 1, tree%n_lvls
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call a$D_gc_box_corners(tree%boxes, id, iv, subr_no_nb, subr_bc)
       end do
       !$omp end do
    end do
  end subroutine a$D_gc_corners

  ! Fill ghost cells for variables iv on the corners of a boxes, using
  ! subr_no_nb on refinement boundaries and subr_bc on physical boundaries
  subroutine a$D_gc_box_corners(boxes, id, iv, subr_no_nb, subr_bc)
    type(box$D_t), intent(inout) :: boxes(:)
    integer, intent(in)         :: id, iv
    procedure(a$D_subr_gc)       :: subr_no_nb, subr_bc
    integer                     :: cn, nbs($D), nb

    do cn = 1, a$D_num_children
       nbs     = a$D_ch_nbs(:, cn)
       have_nb = .false.

       do nb = 1, $D
          if (boxes(id)%neighbors(nbs(nb)) > a5_no_box) then
             call a$D_gc_corner_from_nb(boxes, id, cn, nbs(1), iv)
             cycle
          end if

          if (all(boxes(id)%neighbors(nbs) == a5_no_box)) then
             call subr_no_nb(boxes, id, cn, iv)
          else
             ! There is a boundary condition here
             call subr_bc(boxes, id, cn, iv)
          end if
       end do
     end subroutine a$D_gc_box_corners

     ! Bilinear interpolation from a parent to fill a corner ghost cell
     subroutine a$D_corners_prolong1(boxes, id, cn, iv)
       type(box$D_t), intent(inout) :: boxes(:)
       integer, intent(in)         :: id, cn, iv
       integer                     :: nc

       nc = boxes(id)%n_cell

       select case (cn)
#if $D == 2
       case (a$D_ch_lxly)
          call a2_prolong1_to(boxes, id, [0,0], [0,0], iv)
       case (a2_ch_hxly)
          call a2_prolong1_to(boxes, id, [nc+1, 0], [nc+1,0], iv)
       case (a2_ch_lxhy)
          call a2_prolong1_to(boxes, id, [0, nc+1], [0, nc+1], iv)
       case (a2_ch_hxhy)
          call a2_prolong1_to(boxes, id, [nc+1, nc+1], [nc+1, nc+1], iv)
#elif $D == 3
       case (a3_ch_lxlylz)
          call a3_prolong1_to(boxes, id, [0,0,0], [0,0,0], ivs)
       case (a3_ch_hxlylz)
          call a3_prolong1_to(boxes, id, [nc+1,0,0], [nc+1,0,0], ivs)
       case (a3_ch_lxhylz)
          call a3_prolong1_to(boxes, id, [0,nc+1,0], [0,nc+1,0], ivs)
       case (a3_ch_hxhylz)
          call a3_prolong1_to(boxes, id, [nc+1,nc+1,0], [nc+1,nc+1,0], ivs)
       case (a3_ch_lxlyhz)
          call a3_prolong1_to(boxes, id, [0,0,nc+1], [0,0,nc+1], ivs)
       case (a3_ch_hxlyhz)
          call a3_prolong1_to(boxes, id, [nc+1,0,nc+1], [nc+1,0,nc+1], ivs)
       case (a3_ch_lxhyhz)
          call a3_prolong1_to(boxes, id, [0,nc+1,nc+1], [0,nc+1,nc+1], ivs)
       case (a3_ch_hxhyhz)
          call a3_prolong1_to(boxes, id, [nc+1,nc+1,nc+1], [nc+1,nc+1,nc+1], ivs)
#endif
       end select
     end subroutine a$D_corners_prolong1

     ! Extrapolate corner ghost cell from side ghost cells
     subroutine a$D_corners_extrap(boxes, id, cn, iv)
       type(box$D_t), intent(inout) :: boxes(:)
       integer, intent(in)         :: id, cn, iv
       integer                     :: nc

       nc = boxes(id)%n_cell

       select case (cn)
       case (a$D_ch_lxly)
          boxes(id)%cc(0, 0, iv) = boxes(id)%cc(1, 0, iv) &
               - 0.5_dp * boxes(id)%cc(2, 0, iv) &
               + boxes(id)%cc(0, 1, iv) &
               - 0.5_dp * boxes(id)%cc(0, 2, iv)
       case (a$D_ch_hxly)
          boxes(id)%cc(nc+1, 0, iv) = boxes(id)%cc(nc, 0, iv) &
               - 0.5_dp * boxes(id)%cc(nc-1, 0, iv) &
               + boxes(id)%cc(nc+1, 1, iv) &
               - 0.5_dp * boxes(id)%cc(nc+1, 2, iv)
       case (a$D_ch_lxhy)
          boxes(id)%cc(0, nc+1, iv) = boxes(id)%cc(0, nc, iv) &
               - 0.5_dp * boxes(id)%cc(0, nc-1, iv) &
               + boxes(id)%cc(1, nc+1, iv) &
               - 0.5_dp * boxes(id)%cc(2, nc+1, iv)
       case (a$D_ch_hxhy)
          boxes(id)%cc(nc+1, nc+1, iv) = boxes(id)%cc(nc, nc+1, iv) &
               - 0.5_dp * boxes(id)%cc(nc-1, nc+1, iv) &
               + boxes(id)%cc(nc+1, nc, iv) &
               - 0.5_dp * boxes(id)%cc(nc+1, nc-1, iv)
       end select
     end subroutine a$D_corners_extrap

     ! Fill corner ghost cell from side ghost cells on neighbor
     subroutine a$D_gc_corner_from_nb(boxes, id, cn, nb, iv)
       type(box$D_t), intent(inout) :: boxes(:)
       integer, intent(in)         :: id, cn, nb, iv
       integer                     :: nc, nb_id, ij(2), ij_nb(2), d

       nb_id    = boxes(id)%neighbors(nb)
       nc       = boxes(id)%n_cell
       ij       = a$D_ch_dix(:, cn) * (nc+1)
       ij_nb    = ij
       d        = a$D_nb_dim(nb)
       ij_nb(d) = mod(ij(d) + nc, 2*nc) ! 0 -> nc and nc+1 -> 1

       boxes(id)%cc(ij(1), ij(2), iv) = boxes(nb_id)%cc(ij_nb(1), ij_nb(2), iv)
     end subroutine a$D_gc_corner_from_nb

     ! Restrict fluxes from children to parents on refinement boundaries
     subroutine a$D_consistent_fluxes(tree, f_ixs)
       use omp_lib
       type(a$D_t), intent(inout) :: tree
       integer, intent(in)       :: f_ixs(:)
       integer                   :: lvl, i, id, nb, nb_id

       do lvl = 1, tree%n_lvls-1
          !$omp do
          do i = 1, size(tree%lvls(lvl)%parents)
             id = tree%lvls(lvl)%parents(i)
             do nb = 1, a$D_num_neighbors
                nb_id = tree%boxes(id)%neighbors(nb)
                if (nb_id < a5_no_box) cycle ! Boundary condition
                if (.not. a$D_has_children(tree%boxes(nb_id))) &
                     call a$D_flux_from_children(tree%boxes, id, nb, f_ixs)
             end do
          end do
          !$omp end do nowait
       end do
       !$omp barrier
     end subroutine a$D_consistent_fluxes

     ! The neighbor nb has no children and id does, so get flux from children for
     ! consisency at refinement boundary. TODO: TEST
     subroutine a$D_flux_from_children(boxes, id, nb, f_ixs)
       type(box$D_t), intent(inout) :: boxes(:)
       integer, intent(in)         :: id, nb, f_ixs(:)
       integer                     :: nc, nch, c_id

       nc  = boxes(id)%n_cell
       nch = ishft(nc, -1) ! nc/2

       select case (nb)
       case (a$D_nb_lx)
          c_id = boxes(id)%children(a$D_ch_lxly)
          boxes(id)%fx(       1, 1:nch,  f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fx(1, 1:nc:2, f_ixs) + &
               boxes(c_id)%fx(1, 2:nc:2, f_ixs))
          c_id = boxes(id)%children(a$D_ch_lxhy)
          boxes(id)%fx(       1, nch+1:, f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fx(1, 1:nc:2, f_ixs) + &
               boxes(c_id)%fx(1, 2:nc:2, f_ixs))
       case (a$D_nb_hx)
          c_id = boxes(id)%children(a$D_ch_hxly)
          boxes(id)%fx(       nc+1, 1:nch,  f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fx(nc+1, 1:nc:2, f_ixs) + &
               boxes(c_id)%fx(nc+1, 2:nc:2, f_ixs))
          c_id = boxes(id)%children(a$D_ch_hxhy)
          boxes(id)%fx(       nc+1, nch+1:, f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fx(nc+1, 1:nc:2, f_ixs) + &
               boxes(c_id)%fx(nc+1, 2:nc:2, f_ixs))
       case (a$D_nb_ly)
          c_id = boxes(id)%children(a$D_ch_lxly)
          boxes(id)%fy(       1:nch,  1, f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fy(1:nc:2, 1, f_ixs) + &
               boxes(c_id)%fy(2:nc:2, 1, f_ixs))
          c_id = boxes(id)%children(a$D_ch_hxly)
          boxes(id)%fy(       nch+1:, 1, f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fy(1:nc:2, 1, f_ixs) + &
               boxes(c_id)%fy(2:nc:2, 1, f_ixs))
       case (a$D_nb_hy)
          c_id = boxes(id)%children(a$D_ch_lxhy)
          boxes(id)%fy(       1:nch,  nc+1, f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fy(1:nc:2, nc+1, f_ixs) + &
               boxes(c_id)%fy(2:nc:2, nc+1, f_ixs))
          c_id = boxes(id)%children(a$D_ch_hxhy)
          boxes(id)%fy(       nch+1:, nc+1, f_ixs) = 0.5_dp * ( &
               boxes(c_id)%fy(1:nc:2, nc+1, f_ixs) + &
               boxes(c_id)%fy(2:nc:2, nc+1, f_ixs))
       end select
     end subroutine a$D_flux_from_children

     ! Write the cell centered data of a tree to a vtk file
     subroutine a$D_write_tree(tree, filename, cc_names, n_cycle, time)
       use m_vtk
       type(a$D_t), intent(in) :: tree
       character(len=*)        :: filename, cc_names(:)
       integer, intent(in)     :: n_cycle
       real(dp), intent(in)    :: time
       integer                 :: lvl, bc, bn, n, n_cells, n_nodes, n_grids
       integer                 :: ig, i, j, id, n_ix, c_ix
       integer                 :: cell_ix, node_ix
       integer, parameter      :: n_ch = a$D_num_children
       integer                 :: nodes_per_box, cells_per_box
       real(dp), allocatable   :: coords(:), cc_vars(:,:)
       integer, allocatable    :: offsets(:), connects(:), cell_types(:)
       type(vtk_t)             :: vtkf

       !$omp single

       if (size(cc_names) /= tree%n_var_cell) &
            stop "a$D_write_tree: size(cc_names) /= n_var_cell"

       bc = tree%n_cell         ! number of Box Cells
       bn = tree%n_cell + 1     ! number of Box Nodes
       nodes_per_box = bn**2
       cells_per_box = bc**2

       n_grids = 0
       do lvl = 1, tree%n_lvls
          n_grids = n_grids + size(tree%lvls(lvl)%leaves)
       end do
       n_nodes = nodes_per_box * n_grids
       n_cells = cells_per_box * n_grids

       allocate(coords(2 * n_nodes))
       allocate(cc_vars(n_cells, tree%n_var_cell))
       allocate(offsets(cells_per_box * n_grids))
       allocate(cell_types(cells_per_box * n_grids))
       allocate(connects(n_ch * cells_per_box * n_grids))

       cell_types = 8              ! VTK pixel type

       ig = 0
       do lvl = 1, tree%n_lvls
          do n = 1, size(tree%lvls(lvl)%leaves)
             id = tree%lvls(lvl)%leaves(n)

             ig = ig + 1
             cell_ix = (ig-1) * cells_per_box
             node_ix = (ig-1) * nodes_per_box

             do j = 1, bn
                do i = 1, bn
                   n_ix = 2 * (node_ix + (j-1) * bn + i)
                   coords(n_ix-1:n_ix) = tree%boxes(id)%r_min + &
                        [i-1,j-1] * tree%boxes(id)%dr
                end do
             end do

             do j = 1, bc
                do i = 1, bc
                   ! In vtk, indexing starts at 0, so subtract 1
                   n_ix                      = node_ix + (j-1) * bn + i - 1
                   c_ix                      = cell_ix + (j-1) * bc + i
                   cc_vars(c_ix, :)          = tree%boxes(id)%cc(i, j, :)
                   offsets(c_ix)             = a$D_num_children * c_ix
                   connects(n_ch*(c_ix-1)+1:n_ch*c_ix) = [n_ix, n_ix+1, n_ix+bn, n_ix+bn+1]
                end do
             end do
          end do
       end do

       call vtk_ini_xml(vtkf, trim(filename), 'UnstructuredGrid')
       call vtk_dat_xml(vtkf, "UnstructuredGrid", .true.)
       call vtk_geo_xml(vtkf, coords, n_nodes, n_cells, 2, n_cycle, time)
       call vtk_con_xml(vtkf, connects, offsets, cell_types, n_cells)
       call vtk_dat_xml(vtkf, "CellData", .true.)
       do n = 1, tree%n_var_cell
          call vtk_var_r8_xml(vtkf, trim(cc_names(n)), cc_vars(:, n), n_cells)
       end do
       call vtk_dat_xml(vtkf, "CellData", .false.)
       call vtk_geo_xml_close(vtkf)
       call vtk_dat_xml(vtkf, "UnstructuredGrid", .false.)
       call vtk_end_xml(vtkf)
       print *, "Written ", trim(filename), ", n_grids", n_grids
       !$omp end single
     end subroutine a$D_write_tree

     ! subroutine a$D_write_tree(tree, filename, cc_names, cc_units, n_cycle, time)
     !   use m_write_silo
     !   type(a$D_t), intent(in)          :: tree
     !   character(len=*)                :: filename, cc_names(:), cc_units(:)
     !   integer, intent(in)             :: n_cycle
     !   real(dp), intent(in)            :: time
     !   character(len=*), parameter     :: grid_name = "gg", var_name  = "vv"
     !   character(len=*), parameter     :: amr_name  = "amr"
     !   character(len=100), allocatable :: grid_list(:), var_list(:, :)
     !   integer                         :: lvl, i, id, ig, iv, bs, n_grids, dbix

     !   bs = tree%box_cells
     !   n_grids = 0
     !   do lvl = 1, tree%n_lvls
     !      n_grids = n_grids + size(tree%lvls(lvl)%ids)
     !   end do

     !   allocate(grid_list(n_grids))
     !   allocate(var_list(tree%n_var_cell, n_grids))

     !   call SILO_create_file(filename, dbix)
     !   ig = 0

     !   do lvl = 1, tree%n_lvls
     !      do i = 1, size(tree%lvls(lvl)%ids)
     !         id = tree%lvls(lvl)%ids(i)
     !         ig = ig + 1
     !         write(grid_list(ig), "(A,I0)") grid_name, ig
     !         call SILO_add_grid(dbix, grid_list(ig), 2, &
     !              [bs+1, bs+1], tree%boxes(id)%r_min, tree%boxes(id)%dr)
     !         print *, id, tree%boxes(id)%r_min, tree%boxes(id)%dr
     !         do iv = 1, tree%n_var_cell
     !            write(var_list(iv, ig), "(A,I0)") trim(cc_names(iv)) // "_", ig
     !            call SILO_add_var(dbix, var_list(iv, ig), grid_list(ig), &
     !                 pack(tree%boxes(id)%cc(1:bs, 1:bs, iv), .true.), [bs, bs], &
     !                 trim(cc_units(iv)))
     !         end do
     !      end do
     !   end do

     !   call SILO_set_mmesh_grid(dbix, amr_name, grid_list, n_cycle, time)
     !   do iv = 1, tree%n_var_cell
     !      call SILO_set_mmesh_var(dbix, trim(cc_names(iv)), amr_name, &
     !           var_list(iv, :), n_cycle, time)
     !   end do
     !   call SILO_close_file(dbix)
     !   print *, "Number of grids", ig
     ! end subroutine a$D_write_tree

   end module m_afivo_$D