% devein_all_numbered_masks_update
%
% Persistent UPDATE pipeline using all numbered motor-cluster masks.
% Successful reruns replace only that subject in the accumulated group
% dataset; subjects not rerun are retained, and failed reruns preserve an
% older valid group result.
%
% Each mask may use a different LN2_COLUMNS file (for example columns7 or
% columns4). The positive column labels actually present are used and are
% remapped to globally unique IDs before LN2_DEVEIN.
%
% Both pre-devein (called RawMean for backward compatibility) and deveined
% beta/contrast values are saved. Model 1 positive interaction is defined as
% (Active-Relax)_Tap - (Active-Relax)_NoTap, matching the thesis convention.
%
clear; clc;

%% ========================= USER SETTINGS =========================

% Add or remove subjects here. You can run separate batches on different
% days: the group files are UPDATED rather than replaced by the current batch.
subjects = {'S11'};

cfg.pipelineVersion = '2026-08-27_update_v3';
cfg.interactionConvention = 'TapMinusNoTap_is_positive';

cfg.projectRoot = '/data/xd25/Laminar_hallucinations';
cfg.subjectDataRoot = fullfile(cfg.projectRoot, 'Subject_data');
cfg.spmDir = '/home/xd25/spm/spm';

cfg.nRuns = 4;
cfg.runPattern = 'rNORDIC_run_%d_trimmed_upsampled.nii';

% Only explicit numbered masks are treated as original masks:
%   ...mask0.nii, ...mask1.nii, ...mask2.nii, ...
cfg.maskRegex = '^Non_p_corrected_motor_clusters_upsampled_mask([0-9]+)\.nii$';
cfg.layerSuffix = '_layers_equivol.nii';

% Each mask may use a different requested number of columns. Exactly one
% matching file is discovered for every mask, for example:
%   ...mask0_columns7.nii
%   ...mask1_columns4.nii
% The positive labels actually present in that file are used.
cfg.columnRegexSuffix = '_columns([0-9]+)\.nii$';

% Model files preserved from the original workflow.
cfg.model1SpmName = 'SPM.mat';
cfg.model2TaskSpmName = 'SPM (2).mat';
cfg.model2NuisSpmName = 'SPM.mat';
cfg.runModel2 = true;
cfg.requireModel2 = false;

cfg.ln2Devein = 'LN2_DEVEIN';
cfg.deveinMethod = 'deconv';       % 'deconv', 'CBV', or 'linear'
cfg.lambda = [];                   % [] uses the LayNii default
cfg.runLayniiDevein = true;

cfg.alfFwhmVolumes = 6;
cfg.alfFloorPercentile = 1;
cfg.writeResidual4D = false;

cfg.nLayers = 3;
cfg.layerNames = {'Deep', 'Middle', 'Superficial'};
cfg.affineTolerance = 1e-4;
cfg.outputFolderName = 'all_numbered_masks_voxelwise_devein_outputs';
cfg.groupOutputFolderName = 'all_numbered_masks_devein_group_results';
cfg.groupStateFileName = 'all_subjects_devein_results.mat';
cfg.groupSchemaVersion = 3;

% Numbered masks are expected to be separate pieces of cortex. If two masks
% overlap, the script stops because independently generated column systems
% are ambiguous at the overlapping voxels.
cfg.errorOnMaskOverlap = true;

% Failed reruns do not erase an older valid subject entry from the group.
cfg.preserveOldGroupDataOnFailure = true;

% Accept S9, S09 or 9 and convert to S09.
subjects = normalize_subject_ids(subjects);

%% ========================= SET UP SPM =========================

if exist(cfg.spmDir, 'dir') == 7
    addpath(cfg.spmDir);
end

if exist('spm_vol', 'file') ~= 2
    error('SPM was not found. Edit cfg.spmDir or add SPM to the MATLAB path.');
end

%% ========================= CURRENT BATCH =========================

newLayerLong = table();
newMaskInventory = table();
newFailures = empty_devein_failure_table();
statusRows = {};

fprintf('\n============================================================\n');
fprintf('All-numbered-mask voxel-wise GLM + LN2_DEVEIN\n');
fprintf('Persistent UPDATE mode\n');
fprintf('Subjects: %s\n', strjoin(subjects, ', '));
fprintf('============================================================\n');

for s = 1:numel(subjects)
    subj = char(subjects{s});
    subjDir = fullfile(cfg.subjectDataRoot, subj, sprintf('%s_for_LayNii', subj));

    fprintf('\n============================================================\n');
    fprintf('Subject %d/%d: %s\n', s, numel(subjects), subj);
    fprintf('Directory: %s\n', subjDir);
    fprintf('============================================================\n');

    try
        [T_layer_long, T_mask_inventory] = ...
            process_subject_all_masks(subj, subjDir, cfg);

        newLayerLong = append_devein_table(newLayerLong, T_layer_long);
        newMaskInventory = append_devein_table(newMaskInventory, T_mask_inventory);

        statusRows(end+1, :) = {subj, true, ...
            'Subject completed; its previous group entry will be replaced.'}; %#ok<AGROW>

    catch ME
        warning('%s failed: %s', subj, ME.message);

        failureRow = table({subj}, {ME.message}, ...
            'VariableNames', {'Subject', 'Message'});
        newFailures = append_devein_table(newFailures, failureRow);

        statusRows(end+1, :) = {subj, false, ME.message}; %#ok<AGROW>
    end
end

if isempty(statusRows)
    updateStatus = cell2table(cell(0, 3), ...
        'VariableNames', {'Subject','MergedIntoGroup','Message'});
else
    updateStatus = cell2table(statusRows, ...
        'VariableNames', {'Subject','MergedIntoGroup','Message'});
end

%% ========================= PERSISTENT GROUP UPDATE =========================

groupOutDir = fullfile(cfg.subjectDataRoot, cfg.groupOutputFolderName);
if exist(groupOutDir, 'dir') ~= 7
    mkdir(groupOutDir);
end

[groupLayerLong, groupMaskInventory, T_failed] = ...
    update_devein_group_results(newLayerLong, newMaskInventory, ...
    newFailures, subjects, groupOutDir, cfg);

safe_writetable(updateStatus, fullfile(groupOutDir, 'last_update_status.csv'));

if isempty(groupLayerLong)
    groupRawWide = table();
    groupDeveinedWide = table();
    groupUnionLong = table();
else
    groupLayerLong = migrate_interaction_names(groupLayerLong);

    groupRawWide = unstack(groupLayerLong(:, ...
        {'Subject','Scope','MaskID','MaskName','Model','Contrast', ...
        'DeVeinMethod','Layer','RawMean'}), 'RawMean', 'Layer');

    groupDeveinedWide = unstack(groupLayerLong(:, ...
        {'Subject','Scope','MaskID','MaskName','Model','Contrast', ...
        'DeVeinMethod','Layer','DeveinedMean'}), 'DeveinedMean', 'Layer');

    groupUnionLong = groupLayerLong(strcmp(groupLayerLong.Scope, 'AllMasksUnion'), :);
end

safe_writetable(groupLayerLong, ...
    fullfile(groupOutDir, 'all_subjects_devein_layer_long.csv'));
safe_writetable(groupRawWide, ...
    fullfile(groupOutDir, 'all_subjects_devein_raw_wide.csv'));
safe_writetable(groupRawWide, ...
    fullfile(groupOutDir, 'all_subjects_devein_predevein_wide.csv'));
safe_writetable(groupDeveinedWide, ...
    fullfile(groupOutDir, 'all_subjects_devein_deveined_wide.csv'));
safe_writetable(groupUnionLong, ...
    fullfile(groupOutDir, 'all_subjects_devein_all_masks_union_long.csv'));
safe_writetable(groupMaskInventory, ...
    fullfile(groupOutDir, 'all_subjects_mask_inventory.csv'));
safe_writetable(T_failed, ...
    fullfile(groupOutDir, 'all_subjects_devein_failures.csv'));

updateInfo = struct();
updateInfo.timestamp = datestr(now, 30);
updateInfo.attemptedSubjects = subjects;
if isempty(newLayerLong) || ...
        ~ismember('Subject', newLayerLong.Properties.VariableNames)
    updateInfo.successfulSubjects = {};
else
    updateInfo.successfulSubjects = cellstr( ...
        unique(string(newLayerLong.Subject), 'stable'));
end
updateInfo.updateRule = ['Successful current subjects replace old rows; ' ...
    'unrequested subjects and older valid rows from failed reruns are retained.'];

% Current names plus compatibility aliases for earlier program versions.
allLayerLong = groupLayerLong;
allRawWide = groupRawWide;
allDeveinedWide = groupDeveinedWide;
allUnionLong = groupUnionLong;
allMaskInventory = groupMaskInventory;
allFailures = T_failed;

save(fullfile(groupOutDir, cfg.groupStateFileName), ...
    'allLayerLong', 'allRawWide', 'allDeveinedWide', ...
    'allUnionLong', 'allMaskInventory', 'allFailures', ...
    'groupLayerLong', 'groupRawWide', 'groupDeveinedWide', ...
    'groupUnionLong', 'groupMaskInventory', 'T_failed', ...
    'updateStatus', 'updateInfo', 'cfg', '-v7.3');

fprintf('\n============================================================\n');
fprintf('Persistent group results updated.\n');
if isempty(groupLayerLong)
    fprintf('Total subjects currently in group dataset: 0\n');
else
    fprintf('Total subjects currently in group dataset: %d\n', ...
        numel(unique(string(groupLayerLong.Subject))));
end
fprintf('Results: %s\n', groupOutDir);
fprintf('============================================================\n');

disp(updateStatus);

%% ========================================================================
% Process one subject
% ========================================================================

function [T_layer_long, T_mask_inventory] = process_subject_all_masks(subj, subjDir, cfg)

if exist(subjDir, 'dir') ~= 7
    error('Subject directory does not exist: %s', subjDir);
end

outDir = fullfile(subjDir, cfg.outputFolderName);
if exist(outDir, 'dir') ~= 7
    mkdir(outDir);
end

%% Find and check the four functional runs
runFiles = cell(cfg.nRuns, 1);
Vrun = cell(cfg.nRuns, 1);
nScanPerRun = zeros(cfg.nRuns, 1);

for r = 1:cfg.nRuns
    runFiles{r} = fullfile(subjDir, sprintf(cfg.runPattern, r));
    if exist(runFiles{r}, 'file') ~= 2
        error('Run file not found: %s', runFiles{r});
    end

    Vrun{r} = spm_vol(runFiles{r});
    nScanPerRun(r) = numel(Vrun{r});
end

Vref = Vrun{1}(1);
refDim = Vref.dim;

for r = 2:cfg.nRuns
    assert_same_grid_headers(Vref, Vrun{r}(1), cfg.affineTolerance, ...
        sprintf('%s run %d', subj, r));
end

%% Discover all numbered masks and their matching layer/column files
maskRecords = discover_numbered_masks(subjDir, cfg);
nMasks = numel(maskRecords);

fprintf('Found %d numbered masks:\n', nMasks);
for m = 1:nMasks
    fprintf('  mask%d: %s\n', maskRecords(m).MaskID, maskRecords(m).MaskFile);
end

combinedROI = false(refDim);
combinedLayers = zeros(refDim, 'int32');
combinedColumns = zeros(refDim, 'int32');
maskMembership = zeros(refDim, 'int32');

nextGlobalColumn = int32(1);

for m = 1:nMasks
    assert_same_grid_file(Vref, maskRecords(m).MaskFile, cfg.affineTolerance, ...
        sprintf('%s mask%d', subj, maskRecords(m).MaskID));
    assert_same_grid_file(Vref, maskRecords(m).LayerFile, cfg.affineTolerance, ...
        sprintf('%s mask%d layer file', subj, maskRecords(m).MaskID));
    assert_same_grid_file(Vref, maskRecords(m).ColumnFile, cfg.affineTolerance, ...
        sprintf('%s mask%d column file', subj, maskRecords(m).MaskID));

    roi = spm_read_vols(spm_vol(maskRecords(m).MaskFile)) > 0;
    layers = round(spm_read_vols(spm_vol(maskRecords(m).LayerFile)));
    columns = round(spm_read_vols(spm_vol(maskRecords(m).ColumnFile)));

    valid = roi & isfinite(layers) & isfinite(columns) & layers > 0 & columns > 0;

    badLayer = valid & ~ismember(layers, 1:cfg.nLayers);
    if any(badLayer(:))
        badLabels = unique(layers(badLayer));
        error('mask%d contains unexpected layer labels: %s', ...
            maskRecords(m).MaskID, mat2str(badLabels(:)'));
    end

    overlap = combinedROI & valid;
    if any(overlap(:))
        overlapCount = nnz(overlap);
        if cfg.errorOnMaskOverlap
            error(['mask%d overlaps earlier numbered masks in %d valid voxels. ' ...
                'The independently generated column systems are ambiguous there.'], ...
                maskRecords(m).MaskID, overlapCount);
        else
            warning('mask%d overlaps earlier masks in %d voxels; overlapping voxels are excluded from this mask.', ...
                maskRecords(m).MaskID, overlapCount);
            valid(overlap) = false;
        end
    end

    localColumnIDs = unique(columns(valid));
    localColumnIDs = localColumnIDs(isfinite(localColumnIDs) & localColumnIDs > 0);
    localColumnIDs = sort(localColumnIDs(:));

    if isempty(localColumnIDs)
        error('mask%d has no valid positive column labels.', maskRecords(m).MaskID);
    end

    if numel(localColumnIDs) ~= maskRecords(m).RequestedColumnCount
        warning(['mask%d column file requests %d columns but contains %d ' ...
            'positive labels. The actual positive labels will be used.'], ...
            maskRecords(m).MaskID, maskRecords(m).RequestedColumnCount, ...
            numel(localColumnIDs));
    end

    firstGlobalColumn = double(nextGlobalColumn);

    % Each mask was columnified independently, so local labels such as 1:7
    % are remapped to globally unique labels before all masks are combined.
    for c = 1:numel(localColumnIDs)
        localID = localColumnIDs(c);
        voxelSelection = valid & columns == localID;
        combinedColumns(voxelSelection) = nextGlobalColumn;
        nextGlobalColumn = nextGlobalColumn + int32(1);
    end

    lastGlobalColumn = double(nextGlobalColumn - int32(1));

    combinedROI(valid) = true;
    combinedLayers(valid) = int32(layers(valid));
    maskMembership(valid) = int32(m);

    maskRecords(m).RimVoxels = nnz(roi);
    maskRecords(m).ValidVoxelsBeforeDataCheck = nnz(valid);
    maskRecords(m).LocalColumnCount = numel(localColumnIDs);
    maskRecords(m).GlobalColumnStart = firstGlobalColumn;
    maskRecords(m).GlobalColumnEnd = lastGlobalColumn;
end

if ~any(combinedROI(:))
    error('The union of all numbered masks is empty.');
end

%% Extract all union-mask voxel time series
linIdx = find(combinedROI);
[x, y, z] = ind2sub(refDim, linIdx);
XYZroi = [x'; y'; z'];

nScanTotal = sum(nScanPerRun);
Y = zeros(nScanTotal, numel(linIdx), 'single');

row0 = 0;
for r = 1:cfg.nRuns
    nT = nScanPerRun(r);
    rows = row0 + (1:nT);

    vals = spm_get_data(Vrun{r}, XYZroi);
    if size(vals, 1) ~= nT && size(vals, 2) == nT
        vals = vals';
    end
    if size(vals, 1) ~= nT || size(vals, 2) ~= numel(linIdx)
        error('Unexpected spm_get_data dimensions for run %d: %s', r, mat2str(size(vals)));
    end

    Y(rows, :) = single(vals);
    row0 = row0 + nT;
end

clear vals;

goodVox = all(isfinite(Y), 1);
if ~all(goodVox)
    nBad = sum(~goodVox);
    warning('%s: excluding %d union-mask voxels with non-finite values.', subj, nBad);

    badLinIdx = linIdx(~goodVox);
    combinedROI(badLinIdx) = false;
    combinedLayers(badLinIdx) = 0;
    combinedColumns(badLinIdx) = 0;
    maskMembership(badLinIdx) = 0;

    linIdx = linIdx(goodVox);
    XYZroi = XYZroi(:, goodVox);
    Y = Y(:, goodVox);
end

if isempty(linIdx)
    error('No finite union-mask voxels remain after reading all runs.');
end

%% Write the combined geometry used by LN2_DEVEIN
unionMaskFile = fullfile(outDir, 'all_masks_union_mask.nii');
combinedLayerFile = fullfile(outDir, 'all_masks_layers_equivol.nii');
combinedColumnFile = fullfile(outDir, 'all_masks_columns_unique.nii');
membershipFile = fullfile(outDir, 'all_masks_membership.nii');

write_3d_nifti(single(combinedROI), unionMaskFile, Vref, 'All numbered masks: valid union');
write_3d_nifti(single(combinedLayers), combinedLayerFile, Vref, 'All numbered masks: layers');
write_3d_nifti(single(combinedColumns), combinedColumnFile, Vref, 'All numbered masks: unique columns');
write_3d_nifti(single(maskMembership), membershipFile, Vref, 'Internal mask membership index');

fprintf('Union voxels used: %d\n', numel(linIdx));
fprintf('Globally unique columns: %d\n', double(nextGlobalColumn - int32(1)));

%% Load model 1 and fit the original voxel-wise OLS model
model1Path = fullfile(subjDir, cfg.model1SpmName);
if exist(model1Path, 'file') ~= 2
    error('Model 1 SPM file not found: %s', model1Path);
end

D = load(model1Path);
SPM1 = D.SPM;
assert_spm_scan_structure(SPM1, nScanPerRun, 'Model 1');

X1 = double(SPM1.xX.X);
names1 = string(SPM1.xX.name(:));

if size(X1, 1) ~= size(Y, 1)
    error('Model 1 design has %d rows but concatenated data have %d scans.', ...
        size(X1, 1), size(Y, 1));
end

fprintf('Fitting Model 1 voxel-wise GLM across all masks...\n');
B1 = pinv(X1) * double(Y);

idxNoTapActive = contains(names1, ' noTapActive*bf(1)');
idxTapRelax = contains(names1, ' tapRelax*bf(1)');
idxTapActive = contains(names1, ' tapActive*bf(1)');
idxNoTapRelax = contains(names1, ' noTapRelax*bf(1)');

check_nonempty(idxNoTapActive, 'Model1 noTapActive');
check_nonempty(idxNoTapRelax, 'Model1 noTapRelax');
check_nonempty(idxTapActive, 'Model1 tapActive');
check_nonempty(idxTapRelax, 'Model1 tapRelax');

bNoTapActive = mean(B1(idxNoTapActive, :), 1, 'omitnan');
bNoTapRelax = mean(B1(idxNoTapRelax, :), 1, 'omitnan');
bTapActive = mean(B1(idxTapActive, :), 1, 'omitnan');
bTapRelax = mean(B1(idxTapRelax, :), 1, 'omitnan');

cMainTap = -bNoTapActive - bNoTapRelax + bTapActive + bTapRelax;
cPositiveGSR = bNoTapActive - bNoTapRelax + bTapActive - bTapRelax;
cNegativeGSR = -bNoTapActive + bNoTapRelax - bTapActive + bTapRelax;

% Thesis-consistent interaction direction:
% positive = (TapActive - TapRelax) - (NoTapActive - NoTapRelax)
%          = GSR/BOLD relation more positive for Tap than for NoTap.
cInteractionTapMinusNoTap = ...
    -bNoTapActive + bNoTapRelax + bTapActive - bTapRelax;
cInteractionNoTapMinusTap = -cInteractionTapMinusNoTap;

maps = struct('Model', {}, 'Contrast', {}, 'Values', {}, 'RawFile', {}, ...
    'DeveinedFile', {}, 'DeVeinMethod', {});

maps = add_map(maps, 'Model1', 'noTapActive', bNoTapActive, outDir);
maps = add_map(maps, 'Model1', 'noTapRelax', bNoTapRelax, outDir);
maps = add_map(maps, 'Model1', 'tapActive', bTapActive, outDir);
maps = add_map(maps, 'Model1', 'tapRelax', bTapRelax, outDir);
maps = add_map(maps, 'Model1', 'Main_Tap', cMainTap, outDir);
maps = add_map(maps, 'Model1', 'Positive_GSR', cPositiveGSR, outDir);
maps = add_map(maps, 'Model1', 'Negative_GSR', cNegativeGSR, outDir);
maps = add_map(maps, 'Model1', 'Positive_interaction_TapMinusNoTap', ...
    cInteractionTapMinusNoTap, outDir);
maps = add_map(maps, 'Model1', 'Negative_interaction_NoTapMinusTap', ...
    cInteractionNoTapMinusTap, outDir);

%% Build and fit the original hybrid Model 2 when available
X2 = [];
names2 = strings(0, 1);
B2 = [];
bTapping = [];
bGSR = [];
bInteraction = [];
model2WasRun = false;

model2TaskPath = fullfile(subjDir, cfg.model2TaskSpmName);
model2NuisPath = fullfile(subjDir, cfg.model2NuisSpmName);

if cfg.runModel2
    model2FilesExist = exist(model2TaskPath, 'file') == 2 && exist(model2NuisPath, 'file') == 2;

    if ~model2FilesExist
        message = sprintf('Model 2 files are missing. Task: %s | Nuisance: %s', ...
            model2TaskPath, model2NuisPath);
        if cfg.requireModel2
            error('%s', message);
        else
            warning('%s. Model 2 will be skipped for %s.', message, subj);
        end
    else
        D = load(model2TaskPath);
        SPM2task = D.SPM;
        D = load(model2NuisPath);
        SPM2nuis = D.SPM;

        assert_spm_scan_structure(SPM2task, nScanPerRun, 'Model 2 task SPM');
        assert_spm_scan_structure(SPM2nuis, nScanPerRun, 'Model 2 nuisance SPM');

        if size(SPM2task.xX.X, 1) ~= size(Y, 1) || size(SPM2nuis.xX.X, 1) ~= size(Y, 1)
            error('Model 2 design row count does not match the concatenated data.');
        end

        fprintf('Building and fitting Model 2 hybrid voxel-wise GLM across all masks...\n');
        X2 = [];
        names2Cell = {};

        for r = 1:cfg.nRuns
            if numel(SPM2task.Sess(r).col) < 4
                error('Model 2 task SPM session %d has fewer than 4 local columns.', r);
            end
            if numel(SPM2nuis.Sess(r).col) < 16
                error('Model 2 nuisance SPM session %d has fewer than 16 local columns.', r);
            end

            taskCols = SPM2task.Sess(r).col(1:4);
            taskCols = taskCols(:)';

            nuisCols = SPM2nuis.Sess(r).col(5:16);
            nuisCols = nuisCols(:)';

            X2 = [X2, ...
                SPM2task.xX.X(:, taskCols), ...
                SPM2nuis.xX.X(:, nuisCols)]; %#ok<AGROW>

            names2Cell = [names2Cell, ...
                SPM2task.xX.name(taskCols), ...
                SPM2nuis.xX.name(nuisCols)]; %#ok<AGROW>
        end

        constantCols = SPM2nuis.xX.iB;
        constantCols = constantCols(:)';

        X2 = double([X2, SPM2nuis.xX.X(:, constantCols)]);
        names2Cell = [names2Cell, SPM2nuis.xX.name(constantCols)];
        names2 = string(names2Cell(:));

        B2 = pinv(X2) * double(Y);

        idxTapping = contains(names2, 'stimulusxTapping^1*bf(1)');
        idxGSR = contains(names2, 'stimulusxGSR^1*bf(1)') & ...
            ~contains(names2, 'stimulusxGSRxTapping^1*bf(1)');
        idxInteraction = contains(names2, 'stimulusxGSRxTapping^1*bf(1)');

        check_nonempty(idxTapping, 'Model2 Tapping');
        check_nonempty(idxGSR, 'Model2 GSR');
        check_nonempty(idxInteraction, 'Model2 Interaction');

        bTapping = mean(B2(idxTapping, :), 1, 'omitnan');
        bGSR = mean(B2(idxGSR, :), 1, 'omitnan');
        bInteraction = mean(B2(idxInteraction, :), 1, 'omitnan');

        maps = add_map(maps, 'Model2', 'Tapping', bTapping, outDir);
        maps = add_map(maps, 'Model2', 'GSR', bGSR, outDir);
        maps = add_map(maps, 'Model2', 'Interaction', bInteraction, outDir);
        model2WasRun = true;
    end
end

%% Write union-mask lo_BOLD maps
for k = 1:numel(maps)
    write_roi_nifti(maps(k).Values, maps(k).RawFile, Vref, linIdx);
end
fprintf('Wrote %d lo_BOLD maps in %s\n', numel(maps), outDir);

%% Estimate lo_ALF from Model 1 residual slow fluctuations
fprintf('Computing lo_ALF from Model 1 residuals across all masks...\n');
R1 = double(Y) - X1 * B1;
loALFValues = compute_residual_alf(R1, nScanPerRun, cfg.alfFwhmVolumes);

finitePositive = isfinite(loALFValues) & loALFValues > 0;
if ~any(finitePositive)
    error('No finite positive lo_ALF values were produced.');
end

alfFloor = prctile(loALFValues(finitePositive), cfg.alfFloorPercentile);
if ~isfinite(alfFloor) || alfFloor <= 0
    alfFloor = min(loALFValues(finitePositive));
end

loALFValues(~finitePositive) = alfFloor;
loALFValues(loALFValues < alfFloor) = alfFloor;

loALFFile = fullfile(outDir, 'lo_ALF_all_masks.nii');
write_roi_nifti(loALFValues, loALFFile, Vref, linIdx);

if cfg.writeResidual4D
    residual4DFile = fullfile(outDir, 'model1_residuals_all_masks_ROI_4D.nii');
    write_roi_4d_nifti(R1, residual4DFile, Vref, linIdx);
end

clear R1;

%% Run LN2_DEVEIN once per map using the combined unique-column geometry
if cfg.runLayniiDevein
    fprintf('Running LN2_DEVEIN with method: %s\n', cfg.deveinMethod);

    for k = 1:numel(maps)
        safeModel = matlab.lang.makeValidName(maps(k).Model);
        safeContrast = matlab.lang.makeValidName(maps(k).Contrast);
        outFile = fullfile(outDir, sprintf('deveined_%s_%s_%s.nii', ...
            safeModel, safeContrast, lower(cfg.deveinMethod)));

        if exist(outFile, 'file') == 2
            delete(outFile);
        end

        cmd = build_devein_cmd(cfg.ln2Devein, maps(k).RawFile, ...
            combinedLayerFile, combinedColumnFile, loALFFile, outFile, ...
            cfg.deveinMethod, cfg.lambda);

        fprintf('\n[%d/%d] %s | %s\n%s\n', ...
            k, numel(maps), maps(k).Model, maps(k).Contrast, cmd);

        [status, cmdout] = system(cmd);
        fprintf('%s\n', cmdout);

        if status ~= 0
            error('LN2_DEVEIN failed for %s %s.', maps(k).Model, maps(k).Contrast);
        end

        if exist(outFile, 'file') ~= 2
            guessed = guess_laynii_output(outFile, cfg.deveinMethod);
            if exist(guessed, 'file') == 2
                outFile = guessed;
            else
                error('Expected LN2_DEVEIN output was not found: %s', outFile);
            end
        end

        maps(k).DeveinedFile = outFile;
        maps(k).DeVeinMethod = cfg.deveinMethod;
    end
else
    fprintf('Skipping LN2_DEVEIN; raw maps are used as placeholders.\n');
    for k = 1:numel(maps)
        maps(k).DeveinedFile = maps(k).RawFile;
        maps(k).DeVeinMethod = 'none_raw_only';
    end
end

%% Extract results for every mask and for the voxel-weighted union
fprintf('Extracting layer-wise raw and deveined means...\n');

Subject = {};
Scope = {};
MaskID = [];
MaskName = {};
Model = {};
Contrast = {};
DeVeinMethod = {};
Layer = {};
LayerID = [];
Nvox = [];
RawMean = [];
DeveinedMean = [];
RawFile = {};
DeveinedFile = {};

for k = 1:numel(maps)
    rawImg = spm_read_vols(spm_vol(maps(k).RawFile));
    devImg = spm_read_vols(spm_vol(maps(k).DeveinedFile));

    % First save one voxel-weighted result across the union of all masks.
    [Subject, Scope, MaskID, MaskName, Model, Contrast, DeVeinMethod, ...
        Layer, LayerID, Nvox, RawMean, DeveinedMean, RawFile, DeveinedFile] = ...
        append_scope_layer_rows(Subject, Scope, MaskID, MaskName, Model, ...
        Contrast, DeVeinMethod, Layer, LayerID, Nvox, RawMean, DeveinedMean, ...
        RawFile, DeveinedFile, subj, 'AllMasksUnion', -1, ...
        'ALL_MASKS_UNION', combinedROI, combinedLayers, rawImg, devImg, ...
        maps(k), cfg);

    % Then save every numbered mask separately.
    for m = 1:nMasks
        thisMask = maskMembership == m;
        maskLabel = sprintf('mask%d', maskRecords(m).MaskID);

        [Subject, Scope, MaskID, MaskName, Model, Contrast, DeVeinMethod, ...
            Layer, LayerID, Nvox, RawMean, DeveinedMean, RawFile, DeveinedFile] = ...
            append_scope_layer_rows(Subject, Scope, MaskID, MaskName, Model, ...
            Contrast, DeVeinMethod, Layer, LayerID, Nvox, RawMean, DeveinedMean, ...
            RawFile, DeveinedFile, subj, 'IndividualMask', ...
            maskRecords(m).MaskID, maskLabel, thisMask, combinedLayers, ...
            rawImg, devImg, maps(k), cfg);
    end
end

T_layer_long = table(Subject, Scope, MaskID, MaskName, Model, Contrast, ...
    DeVeinMethod, Layer, LayerID, Nvox, RawMean, DeveinedMean, RawFile, DeveinedFile);

T_raw_wide = unstack(T_layer_long(:, ...
    {'Subject', 'Scope', 'MaskID', 'MaskName', 'Model', 'Contrast', ...
    'DeVeinMethod', 'Layer', 'RawMean'}), 'RawMean', 'Layer');

T_deveined_wide = unstack(T_layer_long(:, ...
    {'Subject', 'Scope', 'MaskID', 'MaskName', 'Model', 'Contrast', ...
    'DeVeinMethod', 'Layer', 'DeveinedMean'}), 'DeveinedMean', 'Layer');

%% Build mask inventory after the finite-data check
InventorySubject = cell(nMasks, 1);
InventoryMaskID = zeros(nMasks, 1);
InventoryMaskName = cell(nMasks, 1);
RimVoxels = zeros(nMasks, 1);
ValidVoxelsBeforeDataCheck = zeros(nMasks, 1);
FinalVoxels = zeros(nMasks, 1);
RequestedColumnCount = zeros(nMasks, 1);
LocalColumnCount = zeros(nMasks, 1);
GlobalColumnStart = zeros(nMasks, 1);
GlobalColumnEnd = zeros(nMasks, 1);
MaskFile = cell(nMasks, 1);
LayerFile = cell(nMasks, 1);
ColumnFile = cell(nMasks, 1);

for m = 1:nMasks
    InventorySubject{m} = subj;
    InventoryMaskID(m) = maskRecords(m).MaskID;
    InventoryMaskName{m} = sprintf('mask%d', maskRecords(m).MaskID);
    RimVoxels(m) = maskRecords(m).RimVoxels;
    ValidVoxelsBeforeDataCheck(m) = maskRecords(m).ValidVoxelsBeforeDataCheck;
    FinalVoxels(m) = nnz(maskMembership == m);
    RequestedColumnCount(m) = maskRecords(m).RequestedColumnCount;
    LocalColumnCount(m) = maskRecords(m).LocalColumnCount;
    GlobalColumnStart(m) = maskRecords(m).GlobalColumnStart;
    GlobalColumnEnd(m) = maskRecords(m).GlobalColumnEnd;
    MaskFile{m} = maskRecords(m).MaskFile;
    LayerFile{m} = maskRecords(m).LayerFile;
    ColumnFile{m} = maskRecords(m).ColumnFile;
end

T_mask_inventory = table(InventorySubject, InventoryMaskID, InventoryMaskName, ...
    RimVoxels, ValidVoxelsBeforeDataCheck, FinalVoxels, RequestedColumnCount, LocalColumnCount, ...
    GlobalColumnStart, GlobalColumnEnd, MaskFile, LayerFile, ColumnFile, ...
    'VariableNames', {'Subject', 'MaskID', 'MaskName', 'RimVoxels', ...
    'ValidVoxelsBeforeDataCheck', 'FinalVoxels', 'RequestedColumnCount', 'LocalColumnCount', ...
    'GlobalColumnStart', 'GlobalColumnEnd', 'MaskFile', 'LayerFile', 'ColumnFile'});

%% Save subject outputs
writetable(T_layer_long, fullfile(outDir, 'devein_all_masks_layer_long.csv'));
writetable(T_raw_wide, fullfile(outDir, 'devein_all_masks_raw_wide.csv'));
writetable(T_raw_wide, fullfile(outDir, 'devein_all_masks_predevein_wide.csv'));
writetable(T_deveined_wide, fullfile(outDir, 'devein_all_masks_deveined_wide.csv'));
writetable(T_mask_inventory, fullfile(outDir, 'devein_all_masks_inventory.csv'));

resultsFile = fullfile(outDir, 'devein_all_masks_results.mat');
save(resultsFile, ...
    'T_layer_long', 'T_raw_wide', 'T_deveined_wide', 'T_mask_inventory', ...
    'maps', 'maskRecords', 'runFiles', 'nScanPerRun', ...
    'unionMaskFile', 'combinedLayerFile', 'combinedColumnFile', 'membershipFile', ...
    'combinedROI', 'combinedLayers', 'combinedColumns', 'maskMembership', ...
    'linIdx', 'XYZroi', 'loALFFile', 'loALFValues', ...
    'X1', 'names1', 'B1', 'X2', 'names2', 'B2', 'model2WasRun', ...
    'bNoTapActive', 'bNoTapRelax', 'bTapActive', 'bTapRelax', ...
    'cMainTap', 'cPositiveGSR', 'cNegativeGSR', ...
    'cInteractionTapMinusNoTap', 'cInteractionNoTapMinusTap', ...
    'bTapping', 'bGSR', 'bInteraction', 'cfg', '-v7.3');

fprintf('\n%s completed. Results saved in:\n%s\n', subj, outDir);
disp(T_mask_inventory);
disp(T_deveined_wide);

end

%% ========================================================================
% Find numbered masks and companion files
% ========================================================================

function records = discover_numbered_masks(subjDir, cfg)

allNii = dir(fullfile(subjDir, ...
    'Non_p_corrected_motor_clusters_upsampled_mask*.nii'));
records = struct('MaskID', {}, 'MaskFile', {}, 'LayerFile', {}, ...
    'ColumnFile', {}, 'RequestedColumnCount', {}, ...
    'RimVoxels', {}, 'ValidVoxelsBeforeDataCheck', {}, ...
    'LocalColumnCount', {}, 'GlobalColumnStart', {}, ...
    'GlobalColumnEnd', {});

for i = 1:numel(allNii)
    token = regexp(allNii(i).name, cfg.maskRegex, 'tokens', 'once');
    if isempty(token)
        continue;
    end

    maskID = str2double(token{1});
    maskFile = fullfile(allNii(i).folder, allNii(i).name);
    stem = regexprep(allNii(i).name, '\.nii$', '');
    layerFile = fullfile(subjDir, [stem cfg.layerSuffix]);

    if exist(layerFile, 'file') ~= 2
        error('Matching layer file is missing for mask%d: %s', ...
            maskID, layerFile);
    end

    columnCandidates = dir(fullfile(subjDir, [stem '_columns*.nii']));
    validColumnFiles = {};
    requestedCounts = [];
    exactPattern = ['^' regexptranslate('escape', stem) ...
        cfg.columnRegexSuffix];

    for c = 1:numel(columnCandidates)
        columnToken = regexp(columnCandidates(c).name, exactPattern, ...
            'tokens', 'once');
        if ~isempty(columnToken)
            validColumnFiles{end+1, 1} = fullfile( ...
                columnCandidates(c).folder, columnCandidates(c).name); %#ok<AGROW>
            requestedCounts(end+1, 1) = str2double(columnToken{1}); %#ok<AGROW>
        end
    end

    if isempty(validColumnFiles)
        error(['No matching column file was found for mask%d. Expected ' ...
            'a file such as %s_columns7.nii or %s_columns4.nii.'], ...
            maskID, stem, stem);
    end

    if numel(validColumnFiles) > 1
        fileList = strjoin(validColumnFiles, sprintf('\n  '));
        error(['More than one column file was found for mask%d. Keep only ' ...
            'the intended file or move alternatives elsewhere:\n  %s'], ...
            maskID, fileList);
    end

    r = struct();
    r.MaskID = maskID;
    r.MaskFile = maskFile;
    r.LayerFile = layerFile;
    r.ColumnFile = validColumnFiles{1};
    r.RequestedColumnCount = requestedCounts(1);
    r.RimVoxels = NaN;
    r.ValidVoxelsBeforeDataCheck = NaN;
    r.LocalColumnCount = NaN;
    r.GlobalColumnStart = NaN;
    r.GlobalColumnEnd = NaN;

    if isempty(records)
        records = r;
    else
        records(end+1) = r; %#ok<AGROW>
    end
end

if isempty(records)
    error(['No numbered masks were found. Expected names such as ' ...
        'Non_p_corrected_motor_clusters_upsampled_mask0.nii.']);
end

[~, order] = sort([records.MaskID]);
records = records(order);

if numel(unique([records.MaskID])) ~= numel(records)
    error('Duplicate numbered mask IDs were found.');
end

end

%% ========================================================================
% Append one scope (union or individual mask) across all layers
% ========================================================================

function [Subject, Scope, MaskID, MaskName, Model, Contrast, DeVeinMethod, ...
    Layer, LayerID, Nvox, RawMean, DeveinedMean, RawFile, DeveinedFile] = ...
    append_scope_layer_rows(Subject, Scope, MaskID, MaskName, Model, ...
    Contrast, DeVeinMethod, Layer, LayerID, Nvox, RawMean, DeveinedMean, ...
    RawFile, DeveinedFile, subj, scopeLabel, maskIDValue, maskNameValue, ...
    scopeMask, layers, rawImg, devImg, mapInfo, cfg)

for layerIDValue = 1:cfg.nLayers
    layerMask = scopeMask & layers == layerIDValue;

    Subject{end+1, 1} = subj; %#ok<AGROW>
    Scope{end+1, 1} = scopeLabel; %#ok<AGROW>
    MaskID(end+1, 1) = maskIDValue; %#ok<AGROW>
    MaskName{end+1, 1} = maskNameValue; %#ok<AGROW>
    Model{end+1, 1} = mapInfo.Model; %#ok<AGROW>
    Contrast{end+1, 1} = mapInfo.Contrast; %#ok<AGROW>
    DeVeinMethod{end+1, 1} = mapInfo.DeVeinMethod; %#ok<AGROW>
    Layer{end+1, 1} = cfg.layerNames{layerIDValue}; %#ok<AGROW>
    LayerID(end+1, 1) = layerIDValue; %#ok<AGROW>
    Nvox(end+1, 1) = nnz(layerMask); %#ok<AGROW>

    if any(layerMask(:))
        RawMean(end+1, 1) = mean(rawImg(layerMask), 'omitnan'); %#ok<AGROW>
        DeveinedMean(end+1, 1) = mean(devImg(layerMask), 'omitnan'); %#ok<AGROW>
    else
        RawMean(end+1, 1) = NaN; %#ok<AGROW>
        DeveinedMean(end+1, 1) = NaN; %#ok<AGROW>
    end

    RawFile{end+1, 1} = mapInfo.RawFile; %#ok<AGROW>
    DeveinedFile{end+1, 1} = mapInfo.DeveinedFile; %#ok<AGROW>
end

end

%% ========================================================================
% Grid and model checks
% ========================================================================

function assert_same_grid_file(Vref, testFile, tolerance, label)
Vtest = spm_vol(testFile);
assert_same_grid_headers(Vref, Vtest(1), tolerance, label);
end

function assert_same_grid_headers(Vref, Vtest, tolerance, label)
if any(Vref.dim ~= Vtest.dim)
    error('%s dimensions do not match the reference. Reference %s; test %s.', ...
        label, mat2str(Vref.dim), mat2str(Vtest.dim));
end

maxDifference = max(abs(Vref.mat(:) - Vtest.mat(:)));
if maxDifference > tolerance
    error('%s affine does not match the reference (maximum difference %.6g; tolerance %.6g).', ...
        label, maxDifference, tolerance);
end
end

function assert_spm_scan_structure(SPM, nScanPerRun, label)
if ~isfield(SPM, 'Sess') || numel(SPM.Sess) < numel(nScanPerRun)
    error('%s has fewer sessions than the number of run files.', label);
end

for r = 1:numel(nScanPerRun)
    if ~isfield(SPM.Sess(r), 'row')
        error('%s session %d has no Sess.row field.', label, r);
    end
    if numel(SPM.Sess(r).row) ~= nScanPerRun(r)
        error('%s session %d has %d rows but run %d has %d scans.', ...
            label, r, numel(SPM.Sess(r).row), r, nScanPerRun(r));
    end
end
end

function check_nonempty(idx, label)
if ~any(idx)
    error('No design columns matched: %s. Check SPM.xX.name patterns.', label);
end
end

%% ========================================================================
% Map construction and NIfTI writers
% ========================================================================

function maps = add_map(maps, modelName, contrastName, values, outDir)
safeModel = matlab.lang.makeValidName(modelName);
safeContrast = matlab.lang.makeValidName(contrastName);
rawFile = fullfile(outDir, sprintf('lo_BOLD_%s_%s.nii', safeModel, safeContrast));

s = struct();
s.Model = char(modelName);
s.Contrast = char(contrastName);
s.Values = double(values(:))';
s.RawFile = rawFile;
s.DeveinedFile = '';
s.DeVeinMethod = '';

if isempty(maps)
    maps = s;
else
    maps(end+1) = s;
end
end

function write_roi_nifti(values, outFile, Vref, linIdx)
values = single(values(:));
if numel(values) ~= numel(linIdx)
    error('write_roi_nifti: values length does not match ROI voxel count.');
end

img = zeros(Vref.dim, 'single');
img(linIdx) = values;
write_3d_nifti(img, outFile, Vref, 'ROI voxel-wise map');
end

function write_3d_nifti(img, outFile, Vref, description)
if exist(outFile, 'file') == 2
    delete(outFile);
end

Vout = Vref;
Vout.fname = outFile;
Vout.n = [1 1];
Vout.dt = [16 0];
Vout.pinfo = [1; 0; 0];
Vout.descrip = description;
spm_write_vol(Vout, single(img));
end

function write_roi_4d_nifti(Y, outFile, Vref, linIdx)
[nT, nVox] = size(Y);
if nVox ~= numel(linIdx)
    error('write_roi_4d_nifti: Y voxel dimension does not match ROI voxel count.');
end

if exist(outFile, 'file') == 2
    delete(outFile);
end

for t = 1:nT
    img = zeros(Vref.dim, 'single');
    img(linIdx) = single(Y(t, :));

    Vout = Vref;
    Vout.fname = outFile;
    Vout.dt = [16 0];
    Vout.pinfo = [1; 0; 0];
    Vout.n = [t 1];
    Vout.descrip = 'Model 1 ROI residuals';
    spm_write_vol(Vout, img);
end
end

%% ========================================================================
% ALF and LN2_DEVEIN helpers
% ========================================================================

function alf = compute_residual_alf(R, nScanPerRun, fwhmVolumes)
sigma = fwhmVolumes / (2 * sqrt(2 * log(2)));
halfWidth = max(1, ceil(3 * sigma));
t = -halfWidth:halfWidth;
g = exp(-(t.^2) ./ (2 * sigma^2));
g = g ./ sum(g);

nVox = size(R, 2);
alfAccumulator = zeros(1, nVox);
row0 = 0;

for r = 1:numel(nScanPerRun)
    rows = row0 + (1:nScanPerRun(r));
    residualRun = double(R(rows, :));

    residualRun = residualRun - mean(residualRun, 1, 'omitnan');
    residualSmooth = conv2(residualRun, g(:), 'same');

    alfAccumulator = alfAccumulator + std(residualSmooth, 0, 1, 'omitnan');
    row0 = row0 + nScanPerRun(r);
end

alf = alfAccumulator ./ numel(nScanPerRun);
end

function cmd = build_devein_cmd(exe, inputFile, layerFile, columnFile, ...
    alfFile, outputFile, method, lambda)

methodLower = lower(method);
cmd = sprintf('"%s" -input "%s" -layer_file "%s"', exe, inputFile, layerFile);

switch methodLower
    case 'linear'
        cmd = sprintf('%s -linear', cmd);
    case 'cbv'
        cmd = sprintf('%s -column_file "%s" -ALF "%s" -CBV', ...
            cmd, columnFile, alfFile);
    case 'deconv'
        cmd = sprintf('%s -column_file "%s" -ALF "%s"', ...
            cmd, columnFile, alfFile);
        if ~isempty(lambda)
            cmd = sprintf('%s -lambda %.8g', cmd, lambda);
        end
    otherwise
        error('Unknown devein method: %s. Use deconv, CBV, or linear.', method);
end

cmd = sprintf('%s -output "%s"', cmd, outputFile);
end

function guessed = guess_laynii_output(outputFile, method)
[pathName, baseName, extension] = fileparts(outputFile);

switch lower(method)
    case 'linear'
        tag = 'deveinLinear';
    case 'cbv'
        tag = 'deveinCBV';
    otherwise
        tag = 'deveinDeconv';
end

candidates = { ...
    fullfile(pathName, [baseName '_' tag extension]), ...
    fullfile(pathName, [baseName '.' tag extension]), ...
    fullfile(pathName, [baseName tag extension])};

guessed = outputFile;
for i = 1:numel(candidates)
    if exist(candidates{i}, 'file') == 2
        guessed = candidates{i};
        return;
    end
end
end

%% ========================================================================
% Persistent group-update helpers
% ========================================================================

function [groupLayerLong, groupMaskInventory, groupFailures] = ...
    update_devein_group_results(newLayerLong, newMaskInventory, ...
    newFailures, attemptedSubjects, groupOutDir, cfg)

stateFile = fullfile(groupOutDir, cfg.groupStateFileName);
layerCsv = fullfile(groupOutDir, 'all_subjects_devein_layer_long.csv');
inventoryCsv = fullfile(groupOutDir, 'all_subjects_mask_inventory.csv');
failureCsv = fullfile(groupOutDir, 'all_subjects_devein_failures.csv');

oldLayerLong = table();
oldMaskInventory = table();
oldFailures = empty_devein_failure_table();

if exist(stateFile, 'file') == 2
    D = load(stateFile);

    if isfield(D, 'allLayerLong')
        oldLayerLong = D.allLayerLong;
    elseif isfield(D, 'groupLayerLong')
        oldLayerLong = D.groupLayerLong;
    elseif isfield(D, 'finalLayerLong')
        oldLayerLong = D.finalLayerLong;
    end

    if isfield(D, 'allMaskInventory')
        oldMaskInventory = D.allMaskInventory;
    elseif isfield(D, 'groupMaskInventory')
        oldMaskInventory = D.groupMaskInventory;
    elseif isfield(D, 'finalMaskInventory')
        oldMaskInventory = D.finalMaskInventory;
    end

    if isfield(D, 'allFailures')
        oldFailures = D.allFailures;
    elseif isfield(D, 'T_failed')
        oldFailures = D.T_failed;
    elseif isfield(D, 'groupFailures')
        oldFailures = D.groupFailures;
    elseif isfield(D, 'finalFailures')
        oldFailures = D.finalFailures;
    end
end

% CSV fallback permits updating an earlier overwrite-only result folder even
% when its MAT file is missing.
if isempty(oldLayerLong) && exist(layerCsv, 'file') == 2
    oldLayerLong = readtable(layerCsv, 'TextType', 'string');
end
if isempty(oldMaskInventory) && exist(inventoryCsv, 'file') == 2
    oldMaskInventory = readtable(inventoryCsv, 'TextType', 'string');
end
if isempty(oldFailures) && exist(failureCsv, 'file') == 2
    oldFailures = readtable(failureCsv, 'TextType', 'string');
end

oldLayerLong = migrate_interaction_names(oldLayerLong);
newLayerLong = migrate_interaction_names(newLayerLong);
oldMaskInventory = upgrade_devein_inventory(oldMaskInventory);
newMaskInventory = upgrade_devein_inventory(newMaskInventory);

oldLayerLong = normalize_devein_text_columns(oldLayerLong);
oldMaskInventory = normalize_devein_text_columns(oldMaskInventory);
oldFailures = normalize_devein_text_columns(oldFailures);
newLayerLong = normalize_devein_text_columns(newLayerLong);
newMaskInventory = normalize_devein_text_columns(newMaskInventory);
newFailures = normalize_devein_text_columns(newFailures);

% Only subjects that completed successfully in the current batch replace
% their previous measurements. A failed rerun does not erase older results.
if isempty(newLayerLong)
    successfulSubjects = strings(0, 1);
else
    successfulSubjects = unique(string(newLayerLong.Subject));
end

oldLayerLong = remove_devein_subject_rows(oldLayerLong, successfulSubjects);
oldMaskInventory = remove_devein_subject_rows( ...
    oldMaskInventory, successfulSubjects);

if ~cfg.preserveOldGroupDataOnFailure
    failedSubjects = setdiff(string(attemptedSubjects), successfulSubjects);
    oldLayerLong = remove_devein_subject_rows(oldLayerLong, failedSubjects);
    oldMaskInventory = remove_devein_subject_rows(oldMaskInventory, failedSubjects);
end

% Failure status is replaced for every subject attempted in this batch.
oldFailures = remove_devein_subject_rows(oldFailures, string(attemptedSubjects));

try
    groupLayerLong = append_devein_table(oldLayerLong, newLayerLong);
catch ME
    error(['Could not merge the previous and current deveining layer tables. ' ...
        'The table schema may come from an incompatible older script. %s'], ...
        ME.message);
end

try
    groupMaskInventory = append_devein_table( ...
        oldMaskInventory, newMaskInventory);
catch ME
    error(['Could not merge the previous and current mask inventories. ' ...
        'The table schema may come from an incompatible older script. %s'], ...
        ME.message);
end

groupFailures = append_devein_table(oldFailures, newFailures);

if ~isempty(groupLayerLong)
    groupLayerLong = sortrows(groupLayerLong, ...
        {'Subject','Scope','MaskID','Model','Contrast','LayerID'});
end
if ~isempty(groupMaskInventory)
    groupMaskInventory = sortrows(groupMaskInventory, ...
        {'Subject','MaskID'});
end
if ~isempty(groupFailures)
    groupFailures = sortrows(groupFailures, {'Subject'});
end

end

function T = upgrade_devein_inventory(T)

if isempty(T)
    return;
end

if ~ismember('RequestedColumnCount', T.Properties.VariableNames)
    T.RequestedColumnCount = nan(height(T), 1);
end

requiredOrder = {'Subject','MaskID','MaskName','RimVoxels', ...
    'ValidVoxelsBeforeDataCheck','FinalVoxels','RequestedColumnCount', ...
    'LocalColumnCount','GlobalColumnStart','GlobalColumnEnd', ...
    'MaskFile','LayerFile','ColumnFile'};

if ~all(ismember(requiredOrder, T.Properties.VariableNames))
    missing = requiredOrder(~ismember(requiredOrder, T.Properties.VariableNames));
    error('Existing devein mask inventory is missing variables: %s', ...
        strjoin(missing, ', '));
end

T = T(:, requiredOrder);

end

function T = migrate_interaction_names(T)

if isempty(T) || ...
        ~all(ismember({'Model','Contrast'}, T.Properties.VariableNames))
    return;
end

model = string(T.Model);
contrast = string(T.Contrast);

% In the earlier version, the names were reversed relative to the thesis:
% old Negative_interaction = TapMinusNoTap (the thesis positive direction)
% old Positive_interaction = NoTapMinusTap.
oldPositive = model == "Model1" & contrast == "Positive_interaction";
oldNegative = model == "Model1" & contrast == "Negative_interaction";

contrast(oldPositive) = "Negative_interaction_NoTapMinusTap";
contrast(oldNegative) = "Positive_interaction_TapMinusNoTap";
T.Contrast = contrast;

end

function T = remove_devein_subject_rows(T, subjects)

if isempty(T) || isempty(subjects) || ...
        ~ismember('Subject', T.Properties.VariableNames)
    return;
end

keep = ~ismember(string(T.Subject), string(subjects));
T = T(keep, :);

end

function T = append_devein_table(T, newRows)

if isempty(newRows)
    return;
end

newRows = normalize_devein_text_columns(newRows);
if isempty(T)
    T = newRows;
    return;
end

T = normalize_devein_text_columns(T);

if ~isequal(T.Properties.VariableNames, newRows.Properties.VariableNames)
    error('Existing and new tables have different variable names.');
end

T = [T; newRows]; %#ok<AGROW>

end

function T = normalize_devein_text_columns(T)

if isempty(T)
    return;
end

for i = 1:width(T)
    name = T.Properties.VariableNames{i};
    value = T.(name);

    if iscellstr(value) || isstring(value) || iscategorical(value) || ischar(value)
        T.(name) = string(value);
    end
end

end

function T = empty_devein_failure_table()

T = table(strings(0, 1), strings(0, 1), ...
    'VariableNames', {'Subject','Message'});

end

function subjects = normalize_subject_ids(subjects)

subjects = cellstr(string(subjects));
for i = 1:numel(subjects)
    value = char(subjects{i});
    token = regexp(value, '(\d+)', 'tokens', 'once');
    if isempty(token)
        error('Could not parse a subject number from: %s', value);
    end
    subjects{i} = sprintf('S%02d', str2double(token{1}));
end
subjects = unique(subjects, 'stable');

end

function safe_writetable(T, filePath)

if width(T) == 0
    fid = fopen(filePath, 'w');
    if fid >= 0
        fclose(fid);
    end
else
    writetable(T, filePath);
end

end
