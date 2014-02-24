    ! This module does post-processing of .data files. For example to importance sample new data,
    ! correct approximate theory (eg. add in lensing), or to compute missing theory (e.g. matter power).

    module ImportanceSampling
    use settings
    use GeneralTypes
    use CalcLike
    use ParamPointSet
    use IO
    implicit none
    private

    Type, extends(TTheoryLikelihoodUser) :: TImportanceSampler
        logical  redo_like, redo_theory
        real(mcp) :: redo_skip = 100
        character(LEN=:), allocatable :: redo_datafile, redo_outroot,redo_like_name
        real(mcp) :: redo_likeoffset = 0
        real(mcp) :: redo_temperature = 1
        integer :: redo_thin = 1
        logical :: redo_change_like_only = .false.

        !This last one is for comparing goodness of fit
        !After importance sampling, you can recompute the likelihoods without the new data, but
        !keeping the weights from the importance sampling, and thereby asses whether the mean
        !likelihood wrt the original distribution of the parameter space after importance sampling
        !is similar to that after, in which case the datasets intersect in a region of high likelihood

        logical :: redo_add = .false.
        !if just want to add new datasets rather than re-computing the entire likelihood

        logical :: redo_from_text = .false.
        !Redo from text files if .data files not available

        logical :: redo_no_new_data  = .false. !true to make no new .data files to save space
    contains
    procedure :: ReadParams => TImportanceSampler_ReadParams
    procedure :: Init => TImportanceSampler_Init
    procedure :: ImportanceSample => TImportanceSampler_ImportanceSample
    end Type TImportanceSampler

    !not supported any more    logical :: txt_theory = .false. !True to put P_k in output chains

    public TImportanceSampler
    contains

    subroutine TImportanceSampler_ReadParams(this, Ini)
    class(TImportanceSampler) :: this
    class(TSettingIni) :: Ini

    this%redo_like = Ini%Read_Logical('redo_likelihoods')
    this%redo_theory = Ini%read_Logical('redo_theory')
    this%redo_datafile = Ini%Read_String('redo_datafile')
    this%redo_outroot = Ini%Read_String('redo_outroot')
    this%redo_like_name = Ini%Read_String('redo_like_name')

    call Ini%Read('redo_likeoffset',this%redo_likeoffset)
    call Ini%Read('redo_temp',this%redo_temperature)
    call Ini%Read('redo_change_like_only',this%redo_change_like_only)
    call Ini%Read('redo_add',this%redo_add)
    call Ini%Read('redo_from_text',this%redo_from_text)
    call Ini%Read('redo_no_new_data',this%redo_no_new_data)
    call Ini%Read('redo_skip',this%redo_skip)
    call Ini%Read('redo_thin',this%redo_thin,min=1)

    if (this%redo_from_text .and. (this%redo_add .or. this%redo_like_name/='')) &
    call Mpistop('redo_new_likes requires .data files, not from text')

    if (this%redo_from_text  .and. this%redo_skip>0.d0 .and. this%redo_skip<1) &
    call Mpistop('redo_from_text currently requires redo_skip==0 or redo_skip>=1')

    !    txt_theory = Ini%Read_Logical('txt_theory',.false.)

    if (this%redo_outroot == '') then
        this%redo_outroot = trim(ExtractFilePath(baseroot))//'post_' &
        // trim(ExtractFileName(baseroot))
    end if

    end subroutine TImportanceSampler_ReadParams


    subroutine TImportanceSampler_Init(this, LikeCalculator)
    class(TImportanceSampler) :: this
    class(TLikeCalculator), target:: LikeCalculator

    select type (LikeCalculator)
    class is (TTheoryLikeCalculator)
        this%LikeCalculator => LikeCalculator
        class default
        call MpiStop('Importance sampling requires TTheoryLikeCalculator')
    end select

    end subroutine TImportanceSampler_Init


    subroutine TImportanceSampler_ImportanceSample(this,InputFile)
    class(TImportanceSampler) :: this
    character(LEN=*), intent(INOUT):: InputFile
    real(mcp) truelike,mult,like
    real(mcp) weight_min, weight_max, mult_sum, mult_ratio, mult_max,weight
    real(mcp) max_like, max_truelike
    integer error,num, debug
    character (LEN=:), allocatable :: post_root
    integer i, infile_handle
    integer :: outdata_handle=-1
    Type (ParamSet) :: Params
    logical :: has_likes(DataLikelihoods%Count)
    class(TDataLikelihood), pointer :: DataLike
    logical :: first = .false., has_chain = .true.
    integer last_file_loc,file_loc, file_size
    integer :: at_beginning=0, ierror, num_used

    flush_write = .false.
    weight_min= 1e30_mcp
    weight_max = -1e30_mcp
    mult_sum = 0
    mult_ratio = 0
    mult_max = -1e30_mcp
    max_like = 1e30_mcp

    max_truelike =1e30_mcp

    debug = 0

    infile_handle = 0
    this%LikeCalculator%Temperature = this%redo_temperature

    if (Feedback>0 .and. this%redo_change_like_only) &
    write (*,*) 'Warning: only changing likelihoods not weights'

    if (this%redo_datafile /= '') InputFile = this%redo_datafile

    if (this%redo_from_text) then
        infile_handle = IO_OpenChainForRead(trim(InputFile)//'.txt')
        if (.not. this%redo_theory) write (*,*) '**You probably want to set redo_theory**'
        if (this%redo_thin>1) write (*,*) 'redo_thin only OK with redo_from_text if input weights are 1'
    else
        if (FileExists(trim(InputFile)//'.data')) then
            infile_handle = IO_OpenDataForRead(trim(InputFile)//'.data')
        else
            write(*,*) 'Chain .data files does not exist: ', MpiRank+1
            has_chain =.false.
        end if
    end if

    post_root = this%redo_outroot

    if (MpiRank==0 .and.BaseParams%NameMapping%nnames/=0) then
        call BaseParams%OutputParamNames(trim(post_root),params_used, add_derived=.true.)
        call BaseParams%OutputParamRanges(trim(post_root))
    end if

    if (has_chain) then
        if (instance /= 0) post_root = numcat(trim(post_root)//'_',instance)

        if (Feedback > 0) then
            if (this%redo_from_text) then
                write (*,*) 'reading from: ' //  trim(InputFile)//'.txt'
            else
                write (*,*) 'reading from: ' //  trim(InputFile)//'.data'
            end if
            write (*,*) 'writing to: ' // trim(post_root)//'.*'
        end if

        write (*,*) 'Using temperature: ', this%LikeCalculator%Temperature

        outfile_handle = IO_OutputOpenForWrite(trim(post_root)//'.txt')
        if (.not. this%redo_no_new_data) outdata_handle = IO_DataOpenForWrite(trim(post_root)//'.data')
        num = 0
        num_used = 0
        Params%Theory => this%LikeCalculator%Config%NewTheory()

        do
            if (this%redo_from_text) then
                error = 0
                Params%P= BaseParams%center
                if (.not. IO_ReadChainRow(infile_handle, mult, like, Params%P, params_used)) exit
                num=num+1
            else
                call Params%ReadModel(infile_handle,has_likes, mult,like, error)
                num=num+1
                if (first .and. this%redo_like_name/='') then
                    first=.false.
                    do i=1, DataLikelihoods%Count
                        DataLike => DataLikelihoods%Item(i)
                        if (DataLike%name==this%redo_like_name) then
                            if (.not. has_likes(i)) &
                            call MpiStop('does not currently have like named:'//trim(this%redo_like_name))
                            has_likes(i)=.true.
                            if (any(.not. has_likes)) call MpiStop('not all other likelihoods exist already')
                            has_likes(i)=.false.
                            this%redo_add =.true.
                            exit
                        end if
                    end do
                end if
                if (this%redo_skip>0.d0 .and. this%redo_skip<1) then
                    at_beginning=at_beginning+1
                    if (at_beginning==1) then
                        inquire(infile_handle, pos=last_file_loc)
                        cycle
                    elseif (at_beginning==2) then
                        inquire(infile_handle, pos=file_loc)
                        inquire(unit=infile_handle, size=file_size)
                        this%redo_skip = file_size/(file_loc-last_file_loc) * this%redo_skip
                        if (Feedback > 0) print *,'skipping ',nint(this%redo_skip), ' models'
                    end if
                end if
            end if

            if (error ==1) then
                if (num==0) call MpiStop('Error reading data file.')
                exit
            end if

            if (num<=this%redo_skip .or. mod(num,this%redo_thin) /= 0) cycle

            num_used=num_used+1

            if (this%redo_like .or. this%redo_add) then
                !Check for new prior before calculating anything
                if (this%LikeCalculator%CheckPriorCuts(Params)==logZero) then
                    if (Feedback >1) write(*,*) 'Model outside new prior bounds: skipped'
                    cycle
                end if
            end if

            if (this%redo_theory) then
                call this%LikeCalculator%GetTheoryForImportance(Params, error)
            else
                error = 0
            end if

            if (error ==0) then
                if (this%redo_like .or. this%redo_add) then
                    !!!!
                    call this%LikeCalculator%UpdateTheoryForLikelihoods(Params)
                    if (this%redo_add) then
                        truelike = this%LikeCalculator%GetLogLikePost(Params, .not. has_likes)
                    else
                        truelike = this%LikeCalculator%GetLogLikePost(Params)
                    end if
                    if (truelike == logZero) then
                        weight = 0
                    else
                        weight = exp(like-truelike+this%redo_likeoffset)
                    end if

                    if (.not. this%redo_change_like_only)  mult = mult*weight
                else
                    truelike = like
                    weight = 1
                end if

                max_like = min(max_like,like)
                max_truelike = min(max_truelike,truelike)

                mult_ratio = mult_ratio + weight
                mult_sum = mult_sum + mult

                if (mult /= 0) then
                    !                    if (txt_theory) then
                    !                        call WriteParamsAndDat(Params, mult,like)
                    !                    else
                    call Params%WriteParams(this%LikeCalculator%Config,mult,like)
                    !                   end if
                    if (.not. this%redo_no_new_data) call Params%WriteModel(outdata_handle, truelike,mult)
                else
                    if (Feedback >1 ) write (*,*) 'Zero weight: new like = ', truelike
                end if

                if (Feedback > 1) write (*,*) num, ' mult= ', real(mult), ' weight = ', real(weight)
                weight_max = max(weight,weight_max)
                weight_min = min(weight,weight_min)
                mult_max = max(mult_max,mult)

            end if

        end do

        close(infile_handle)
        close(outfile_handle)
        if (.not. this%redo_no_new_data) close(outdata_handle)

        if (Feedback>0) then
            write(*,*) 'finished. Processed ',num_used,' models'
            write (*,*) 'max weight= ',weight_max, ' min weight = ',weight_min
            write (*,*) 'mean mult  = ', mult_sum/num_used
            write (*,*) 'mean importance weight (approx evidence ratio) = ',mult_ratio/num_used
            write (*,*) 'effective number of samples =',mult_sum/mult_max
            write (*,*) 'Best redo_likeoffset = ',max_truelike - max_like
        end if

        if ((mult_ratio < 1e-6 .or. mult_ratio > 1e8) .and. .not.this%redo_change_like_only) then
            write (*,*) 'WARNING: use redo_likeoffset to rescale likelihoods'
        end if

    end if


    end subroutine TImportanceSampler_ImportanceSample

    end module ImportanceSampling