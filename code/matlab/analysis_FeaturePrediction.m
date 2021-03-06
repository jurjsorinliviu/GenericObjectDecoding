% analysis_FeaturePrediction    Run feature prediction
%
% Author: Tomoyasu Horikawa <horikawa-t@atr.jp>, Shuntaro C. Aoki <aoki@atr.jp>
%


clear all;


%% Initial settings %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Data settings
% subjectList  : List of subject IDs [cell array]
% dataFileList : List of data files containing brain data for each subject in `subjectList` [cell array]
% featureList  : List of image features [cell array]
% roiList      : List of ROIs [cell array]
% numVoxelList : List of num of voxels included in the analysis for each ROI in `rois` [cell array]

subjectList  = {'Subject1', 'Subject2', 'Subject3', 'Subject4', 'Subject5'};
dataFileList = {'Subject1.mat', 'Subject2.mat', 'Subject3.mat', 'Subject4.mat', 'Subject5.mat'};
roiList      = {'V1', 'V2', 'V3', 'V4', 'FFA', 'LOC', 'PPA', 'LVC', 'HVC',  'VC'};
numVoxelList = { 500,  500,  500,  500,   500,   500,   500,  1000,  1000,  1000};
featureList  = {'cnn1', 'cnn2', 'cnn3', 'cnn4', ...
                'cnn5', 'cnn6', 'cnn7', 'cnn8', ...
                'hmax1', 'hmax2', 'hmax3', 'gist', 'sift'};

% Image feature data
imageFeatureFile = 'ImageFeatures.mat';

%% Directory settings
workDir = pwd;
dataDir = fullfile(workDir, 'data');       % Directory containing brain and image feature data
resultsDir = fullfile(workDir, 'results'); % Directory to save analysis results
lockDir = fullfile(workDir, 'tmp');        % Directory to save lock files

%% File name settings
resultFileNameFormat = @(s, r, f) fullfile(resultsDir, sprintf('%s/%s/%s.mat', s, r, f));

%% Model parameters
nTrain = 200; % Num of total training iteration
nSkip  = 200; % Num of skip steps for display info

%--------------------------------------------------------------------------------%
% Note: The num of training iteration (`nTrain`) was 2000 in the original paper. %
%--------------------------------------------------------------------------------%


%% Analysis Main %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

fprintf('%s started\n', mfilename);

%%----------------------------------------------------------------------
%% Initialization
%%----------------------------------------------------------------------

addpath(genpath('./lib'));

setupdir(resultsDir);
setupdir(lockDir);

%%----------------------------------------------------------------------
%% Load data
%%----------------------------------------------------------------------

%% Load brain data
fprintf('Loading brain data...\n');

for n = 1:length(subjectList)
    [dataset, metadata] = load_data(fullfile(dataDir, dataFileList{n}));

    dat(n).subject = subjectList{n};
    dat(n).dataSet = dataset;
    dat(n).metaData = metadata;
end

%% Load image features
fprintf('Loading image feature data...\n');

[feat.dataSet, feat.metaData] = load_data(fullfile(dataDir, imageFeatureFile));

% Get num of units for each feature
for n = 1:length(featureList)
    numUnits(n) = size(select_data(feat.dataSet, feat.metaData, sprintf('%s = 1', featureList{n})), 2);
end

%%----------------------------------------------------------------------
%% Create analysis parameter matrix (analysisParam)
%%----------------------------------------------------------------------

analysisParam = uint16(zeros(length(subjectList) * length(roiList) * length(featureList), 3));

c = 1;
for iSbj = 1:length(subjectList)
for iRoi = 1:length(roiList)
for iFeat = 1:length(featureList)
    analysisParam(c, :) = [iSbj, iRoi, iFeat];
    c =  c + 1;
end
end
end

if c < size(analysisParam, 1)
    analysisParam(c:end, :) = [];
end

%%----------------------------------------------------------------------
%% Analysis loop
%%----------------------------------------------------------------------

for n = 1:size(analysisParam, 1)

    %% Initialization --------------------------------------------------

    % Get data index in the current analysis
    iSbj = analysisParam(n, 1);
    iRoi = analysisParam(n, 2);
    iFeat = analysisParam(n, 3);

    % Get the number of units
    nUnit = numUnits(iFeat);
    
    % Set analysis ID and a result file name
    analysisId = sprintf('%s-%s-%s-%s', ...
                         mfilename, ...
                         subjectList{iSbj}, ...
                         roiList{iRoi}, ...
                         featureList{iFeat});
    resultFile = resultFileNameFormat(subjectList{iSbj}, ...
                                      roiList{iRoi}, ...
                                      featureList{iFeat});

    % Check or double-running
    if checkfiles(resultFile)
        % Analysis result already exists
        fprintf('Analysis %s is already done and skipped\n', analysisId);
        continue;
    end

    if islocked(analysisId, lockDir)
        % Analysis is already running
        fprintf('Analysis %s is already running and skipped\n', analysisId);
        continue;
    end

    fprintf('Start %s\n', analysisId);
    lockcomput(analysisId, lockDir);

    %% Load data -------------------------------------------------------
    
    %% Get brain data
    voxSelector = sprintf('ROI_%s = 1', roiList{iRoi});
    nVox = numVoxelList{iRoi};

    brainData = select_data(dat(iSbj).dataSet, dat(iSbj).metaData, voxSelector);

    dataType = get_dataset(dat(iSbj).dataSet, dat(iSbj).metaData, 'DataType');
    labels = get_dataset(dat(iSbj).dataSet, dat(iSbj).metaData, 'Label');

    % dataType
    % --------
    %
    % - 1: Training data
    % - 2: Test data (percept)
    % - 3: Test data (imagery)
    %

    %% Get image feature
    layerFeat = select_data(feat.dataSet, feat.metaData, ...
                            sprintf('%s = 1', featureList{iFeat}));
    featType = get_dataset(feat.dataSet, feat.metaData, 'FeatureType');
    imageIds = get_dataset(feat.dataSet, feat.metaData, 'ImageID');

    % featType
    % --------
    %
    % - 1 = training
    % - 2 = test
    % - 3 = category test
    % - 4 = category others
    %

    %% Get brain data for training and test
    indTrain = dataType == 1;       % Index of training data
    indTestPercept = dataType == 2; % Index of percept test data
    indTestimagery = dataType == 3; % index of imagery test data

    trainData = brainData(indTrain, :);
    testPerceptData = brainData(indTestPercept, :);
    testImageryData = brainData(indTestimagery, :);

    trainLabels = labels(indTrain, :);
    testPerceptLabels = labels(indTestPercept, :);
    testimageryLabels = labels(indTestimagery, :);

    %% Preprocessing ---------------------------------------------------
    
    %% Normalize data
    [trainData, xMean, xNorm] = zscore(trainData);

    testPerceptData = bsxfun(@rdivide, bsxfun(@minus, testPerceptData, xMean), xNorm);
    testImageryData = bsxfun(@rdivide, bsxfun(@minus, testImageryData, xMean), xNorm);

    
    %% Loop for each unit ----------------------------------------------    
    results = [];

    for i = 1:nUnit

        fprintf('Unit %d\n', i);
        
        %% Get image features for training
        trainFeat = layerFeat(featType == 1, i);
        trainImageIds = imageIds(featType == 1, :);

        %% Match training features to labels
        trainFeat = get_refdata(trainFeat, trainImageIds, trainLabels);

        %% Preprocessing (normalization of image features)
        [trainFeat, yMean, yNorm] = zscore(trainFeat);

        %% Preprocessing (voxel selection based on correlation)
        cor = fastcorr(trainData, trainFeat);
        [xTrain, selInd] = select_top(trainData, abs(cor), nVox);
        xTestPercept = testPerceptData(:, selInd);
        xTestImagery = testImageryData(:, selInd);
    
        %% Add bias terms and transpose matrixes for SLR functions
        xTrain = add_bias(xTrain)';
        xTestPercept = add_bias(xTestPercept)';
        xTestImagery = add_bias(xTestImagery)';

        trainFeat = trainFeat';

        %% Image feature decoding --------------------------------------

        model = [];
        predict = [];

        %% Model parameters
        param.Ntrain = nTrain;
        param.Nskip  = nSkip;
        param.data_norm = 1;
        param.num_comp = nVox;

        param.xmean = xMean;
        param.xnorm = xNorm;
        param.ymean = yMean;
        param.ynorm = yNorm;
    
        %% Model training
        model = linear_map_sparse_cov(xTrain, trainFeat, model, param);

        %% Image feature prediction
        predictPercept = predict_output(xTestPercept, model, param)';
        predictImagery = predict_output(xTestImagery, model, param)';

        %% Average prediction results for each category
        testPerceptCategory = unique(floor(testPerceptLabels));
        testImageryCategory = unique(floor(testimageryLabels));

        for j = 1:length(testPerceptCategory)
            categ = testPerceptCategory(j);
            predictPerceptCatAve(j, 1) ...
                = mean(predictPercept(floor(testPerceptLabels) == categ));
        end
        for j = 1:length(testImageryCategory)
            categ = testImageryCategory(j);
            predictImageryCatAve(j, 1) ...
                = mean(predictImagery(floor(testimageryLabels) == categ));
        end

        results(i).subject = subjectList{iSbj};
        results(i).roi = roiList{iRoi};
        results(i).feature = featureList{iFeat};
        results(i).unit = i;
        results(i).predictPercept = predictPercept;
        results(i).predictImagery = predictImagery;
        results(i).predictPerceptCatAve = predictPerceptCatAve;
        results(i).predictImageryCatAve = predictImageryCatAve;
        results(i).categoryTestPercept = testPerceptCategory;
        results(i).categoryTestImagery = testImageryCategory;
    end
    
    %% Save data -------------------------------------------------------
    [rDir, rFileBase, rExt] = fileparts(resultFile);
    setupdir(rDir);
        
    save(resultFile, 'results', '-v7.3');
    
    %% Remove lock file ------------------------------------------------
    unlockcomput(analysisId, lockDir);

end

fprintf('%s done\n', mfilename);
