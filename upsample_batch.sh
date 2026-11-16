#!/bin/bash

# Subject IDs
subjects=("S01" "S02" "S03")

# Structural and functional files: cubic interpolation
cu_inputs=(
    "rNORDIC_run_*_trimmed.nii"
    "meanFunctional.nii"
    "rMasked_UNI.nii"
)

# Binary masks: nearest-neighbour interpolation
nn_inputs=(
    "activation_clusters.nii"
)

# Base directory
base_dir="/data/xd25/Laminar_hallucinations/Subject_data"

# Directory to return to
return_dir="/data/xd25/Laminar_hallucinations/Analysis_code/Phase3_ROI_creation/laynii"

# Remove unmatched wildcard patterns
shopt -s nullglob

for subj in "${subjects[@]}"
do
    echo "========================================"
    echo "Processing subject: ${subj}"
    echo "========================================"

    subj_dir="${base_dir}/${subj}/${subj}_for_LayNii"

    if [ ! -d "${subj_dir}" ]; then
        echo "ERROR: Directory does not exist:"
        echo "${subj_dir}"
        echo "Skipping ${subj}..."
        continue
    fi

    cd "${subj_dir}" || continue

    # Process structural and functional files with cubic interpolation
    for pattern in "${cu_inputs[@]}"
    do
        matched_files=( ${pattern} )

        if [ ${#matched_files[@]} -eq 0 ]; then
            echo "WARNING: No file matches: ${pattern}"
            continue
        fi

        for input in "${matched_files[@]}"
        do
            if [ ! -f "${input}" ]; then
                echo "WARNING: File does not exist: ${input}"
                continue
            fi

            output="${input%.nii}_upsampled.nii"

            echo ""
            echo "Processing with Cu: ${input}"

            # Change the target voxel size here
            3dresample \
                -dxyz 0.3 0.3 1.1 \
                -rmode Cu \
                -overwrite \
                -prefix "${output}" \
                -input "${input}"

            if [ $? -ne 0 ]; then
                echo "ERROR: Cu upsampling failed for ${input}"
                continue
            fi

            echo "Finished: ${output}"
        done
    done

    # Process binary masks with nearest-neighbour interpolation
    for pattern in "${nn_inputs[@]}"
    do
        matched_files=( ${pattern} )

        if [ ${#matched_files[@]} -eq 0 ]; then
            echo "WARNING: No file matches: ${pattern}"
            continue
        fi

        for input in "${matched_files[@]}"
        do
            if [ ! -f "${input}" ]; then
                echo "WARNING: File does not exist: ${input}"
                continue
            fi

            output="${input%.nii}_upsampled.nii"

            echo ""
            echo "Processing with NN: ${input}"

            # Change the target voxel size here
            3dresample \
                -dxyz 0.3 0.3 1.1 \
                -rmode NN \
                -overwrite \
                -prefix "${output}" \
                -input "${input}"

            if [ $? -ne 0 ]; then
                echo "ERROR: NN upsampling failed for ${input}"
                continue
            fi

            echo "Finished: ${output}"
        done
    done

    echo ""
    echo "Finished ${subj}"
    echo ""
done

echo "========================================"
echo "All subjects processed!"
echo "========================================"

cd "${return_dir}" || exit 1
echo "Changed directory back to: ${return_dir}"
