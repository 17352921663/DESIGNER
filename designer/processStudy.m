function processStudy(studyPath);
%   processStudy is a MATLAB function designed to provide "hands-off"
%   preprocesxing to diffusion MRI images.
%
%   processStudy(studyDir) procprocesses the input directory 'studyDir' and
%   returns diffusion/kurtosis maps
%
%   Author: Siddhartha Dhiman
%   Date Created: 02/14/2019
%   Matlab 2018b

warning off;
%% Conda Variables
envName = 'py36';

%% Define Paths
addpath(fullfile(pwd,'dependencies'));

%% Locate Study Directory
%   Opens GUI to locate directory
studyPath = uigetdir(pwd,'Select subject directory');

%% Check and Decompress Files if Present
studyDirFolders = dir(studyPath);
compressedFiles = vertcat(dir(fullfile(studyPath,'**/*.zip')),...
    dir(fullfile(studyPath,'**/*.tar')),...
    dir(fullfile(studyPath,'**/*.gz')));

if length(compressedFiles) >= 1
    parfor i = 1:length(compressedFiles)
        %   Check file extension
        [~,name,ext] = fileparts(fullfile(compressedFiles(i).folder,...
            compressedFiles(i).name));
        mkdir(fullfile(compressedFiles(i).folder,name));
        try
            if ext == '.zip';
                unzip(fullfile(compressedFiles(i).folder,...
                    compressedFiles(i).name),...
                    fullfile(compressedFiles(i).folder));
            elseif ext == '.tar'
                untar(fullfile(compressedFiles(i).folder,...
                    compressedFiles(i).name),...
                    fullfile(compressedFiles(i).folder));
            elseif ext == '.gz'
                gunzip(fullfile(compressedFiles(i).folder,...
                    compressedFiles(i).name),...
                    fullfile(compressedFiles(i).folder));
            else
            end
        catch
            fprintf('Corruption detected: skipping uncompression of %s',name);
            continue
        end
    end
end

%   Snap picture of original directory
studyDirFolders = dir(studyPath);

% Clean it up
for i = 1:length(studyDirFolders)
    rmPattern = [".","..",".DS_Store"];
    %   Check for '.'
    if any(contains(studyDirFolders(i).name,rmPattern));
        rmIdx(i) = 1;
    else
        %   If nothing found, don't mark for deletion
        rmIdx(i) = 0;
    end
end
studyDirFolders(rmIdx ~= 0) = [];   %   Apply deletion filter

%   Assign Output
[fp,~,~] = fileparts(studyPath);
outPath = fullfile(fp,'Processing');
if exist(outPath) == 7;
    rmdir(outPath,'s');
    mkdir(outPath);
else
    mkdir(outPath);
end

%% Sort Dicoms
studyDir = vertcat(dir(fullfile(studyPath,['**' filesep '*'])),...
    dir(fullfile(studyPath,['**' filesep '*.dcm']))); %   Recursive directory listing
rmPattern = {'.','.DS_Store'};   %   Remove files beginning with

% Clean-up Dicom Directory Listing
rmIdx = zeros(1,length(studyDir));
for i = 1:length(studyDir)
    %  Check for directories
    if studyDir(i).isdir == 1
        rmIdx(i) = 1;
        
        %   Check for files starting with'.'
    elseif any(startsWith(studyDir(i).name,'.'));
        rmIdx(i) = 1;
        
    else
        %   If nothing found, don't mark for deletion
        rmIdx(i) = 0;
    end
end
studyDir(rmIdx ~= 0) = [];   %   Apply deletion filter
nFiles = length(studyDir);
fprintf('Found %d possible images in %s\n',nFiles,studyPath);
%   Initialize Parallel Data Queue
parQ = parallel.pool.DataQueue;
%   Initialize progress waitbar
parWaitBar = waitbar(0,'Initializing sorting algorithm...',...
    'Name','Sorting dicoms');
%   After receiving new data, update_progress() will be called
fprintf('Sorting dicoms...');
afterEach(parQ,@parProgress);
n_completed = 0;

parfor i = 1:nFiles
    try
        tmp = dicominfo(fullfile(studyDir(i).folder,studyDir(i).name));
    catch
        continue
    end
    %   Replace all '.' in protocol names with '_'
    tmp.ProtocolName = strrep(tmp.ProtocolName,'.','_');
    %   Replace spaces
    tmp.ProtocolName = strrep(tmp.ProtocolName,' ', '_');
    
    %   Define copy/move folder
    defineFolder = fullfile(outPath,tmp.PatientID,...
        sprintf('%s_%d',tmp.ProtocolName,tmp.SeriesNumber));
    
    if ~exist(defineFolder,'dir')
        mkdir(defineFolder);
    end
    
    if ~contains(studyDir(i).name,'.dcm')
        newName = [studyDir(i).name '.dcm'];
    else
        newName = studyDir(i).name;
    end
    copyfile(tmp.Filename,fullfile(defineFolder,newName));
    send(parQ,i);
end
delete(parWaitBar);
fprintf('done\n')

%% Create Subject List
clear rmIdx
subList = dir(outPath);
rmPattern = [".","..",".DS_Store"];
for i = 1:length(subList)
    %   Check for non-directories
    if subList(i).isdir ~= 1
        rmIdx(i) = 1;
        
        %   Check for '.'
    elseif any(contains(subList(i).name,rmPattern));
        rmIdx(i) = 1;
        
    else
        %   If nothing found, don't mark for deletion
        rmIdx(i) = 0;
    end
end
subList(rmIdx ~= 0) = [];   %   Apply deletion filter
subList = {subList(:).name};

%% Unique Protocol List
seriesNames = dir(fullfile(outPath,subList{1}));
if length(seriesNames) > 1
    for i = 2:length(subList)
        tmp = dir(fullfile(outPath,subList{i}));
        seriesNames = vertcat(seriesNames,tmp);
    end
    for i = 1:length(seriesNames)
        seriesList{i} = seriesNames(i).name;
    end
else
    seriesList = seriesNames.name;
end

%   Clean up to remove '.' and '..'
seriesList(strcmp(seriesList(:),'.')) = [];
seriesList(strcmp(seriesList(:),'..')) = [];

%   Remove sequence number
%   Find positions of '_' in strings
for i = 1:length(seriesList)
    tmpIdx = strfind(seriesList{i},'_');
    seriesList(i) = extractBetween(seriesList{i},1,tmpIdx(end)-1);
end

%   Create unique list and count occurence
[seriesUniList,~,seriesUniIdx] = unique(seriesList);
seriesUniCnt = histc(seriesUniIdx,1:numel(seriesUniList));

%   Locate unique protcols which have the same numer of occurences as number
%   of subjects
cmnSeriesIdx = find(seriesUniCnt == numel(subList));

%   Refine unique list down to protcols which only exists in all subjects
seriesUniList = seriesUniList(cmnSeriesIdx);
fprintf('Found the following commonly occuring imaging protocols:\n');

[seriesIdx seriesSel] = listdlg('PromptString','Select relevant sequences:',...
    'SelectionMode','multiple',...
    'OKString','Run Designer',...
    'CancelString','Cancel',...
    'ListSize',[300 500],...
    'ListString',seriesUniList);

%% Create Designer Output Directory
desPath = fullfile(fp,'Output');
mkdir(desPath);
for i = 1:length(subList)
    mkdir(fullfile(desPath,subList{i}));
end

repInput = repmat('%s,',1,numel(seriesIdx));
% Remove comma at the end
repInput = repInput(1:end-1);

%% Run Designer
for i = 1:length(subList)
    subSeriesDir = dir(fullfile(outPath,subList{i}));
    for j = 1:length(subSeriesDir)
        subSeries{j} = subSeriesDir(j).name;
    end
    %   Clean up to remove '.' and '..'
    subSeries(strcmp(subSeries(:),'.')) = [];
    subSeries(strcmp(subSeries(:),'..')) = [];
    
    for j = 1:length(seriesIdx)
        %   Match modified strings for readibility with actual directory
        matchIdx = startsWith(subSeries,seriesUniList(seriesIdx(j)));
        %   If there are more than one strings, pick the one that most
        %   closely matches based on euclidean distance
        if nnz(matchIdx) > 1
            matchLoc = find(matchIdx);
            for k = 1:length(matchLoc)
                strDist(k) = sqrt(strlength(seriesUniList(seriesIdx(j)))...
                    ^2 + strlength(subSeries(matchLoc(k)))^2);
            end
            [~,matchIdx] = min(strDist);
            seriesUniPath(j) = fullfile(outPath,subList{i},...
                subSeries(matchLoc(matchIdx)));
        else
            seriesUniPath(j) = fullfile(outPath,subList{i},...
                subSeries(matchIdx));
        end
        
    end
    desInput = sprintf(repInput,seriesUniPath{:});
    desOutput = sprintf(fullfile(desPath,subList{i}));
    
    %     runDesigner = sprintf('./designer.sh %s %s',...
    %         desInput,desOutput);
    %     runDesigner = sprintf('source activate %s && python designer.py -denoise -extent 5,5,5 -degibbs -rician -mask -prealign -eddy -rpe_header -smooth 1.25 -DKIparams -DTIparams %s %s',...
    %         envName,desInput,desOutput);
    runDesigner = sprintf('source activate %s && python designer.py -denoise -extent 5,5,5 -degibbs -mask -rician -prealign -smooth 1.25 -DKIparams -DTIparams %s %s',...
        envName,desInput,desOutput);
    [s,t] = system(runDesigner,'-echo');
    
    %%  Rename Outputs
    allFiles = dir(desOutput);
    allFiles = allFiles(~startsWith({allFiles.name},'.'));
    for j = 1:length(allFiles)
        tmp = strsplit(allFiles(j).name,'.');
        newName = [tmp{1} '_' subList{i} '.' tmp{2}];
        movefile(fullfile(allFiles(j).folder,allFiles(j).name),...
            fullfile(allFiles(j).folder,newName));
    end
    
    %% Create QC Metrics
    mkdir(fullfile(desOutput,'QC'));
    
    %   Load all files
    bvalPath = dir(fullfile(desOutput,'*bval'));
    bvalPath = fullfile(bvalPath.folder,bvalPath.name);
    bval = round(single(load(bvalPath)));
    
%     bvecPath = dir(fullfile(desOutput,'*bvec'));
%     bvecPath = fullfile(bvecPath.folder,bvecPath.name);
    
    procPath = dir(fullfile(desOutput,['dwi_designer_' subList{i} '.nii']));
    procPath = fullfile(procPath.folder,procPath.name);
    Iproc = niftiread(procPath);
    
    rawPath = dir(fullfile(desOutput,'dwi_raw*'));
    rawPath = fullfile(rawPath.folder,rawPath.name);
    Iraw = niftiread(rawPath);
    
    noisePath = dir(fullfile(desOutput,'fullnoisemap*'));
    noisePath = fullfile(noisePath.folder,noisePath.name);
    Inoise = niftiread(noisePath);
    
    brainPath = dir(fullfile(desOutput,'brain_mask*'));
    brainPath = fullfile(brainPath.folder,brainPath.name);
    brainMask = logical(niftiread(brainPath));
    
%     csfPath = dir(fullfile(desOutput,'CSFmask*'));
%     csfPath = fullfile(csfPath.folder,csfPath.name);
%     csfMask = logical(niftiread(csfPath));
    
    %   Create logical indexes of bvalues
    listBval = unique(bval);
    bIdx = zeros(length(listBval),length(bval));
    for j = 1:length(listBval)
        bIdx(j,:) = bval == listBval(j);
    end
    bIdx = logical(bIdx);
    
    %   Form index vector for mean 4D array
    nB0 = find(bIdx(1,:));
    meanIdx = horzcat(repmat(listBval(1),[1 numel(nB0)]),listBval(2:end));
    
    %   Compute mean array by initializing it first
    
    meanProc = Iproc(:,:,:,nB0) ./ Inoise;
    meanRaw = Iraw(:,:,:,nB0) ./ Inoise;
    
    for j = 1:length(listBval)
        if j == 1;
            %   Skip B0 because already concatenated
            continue;
        else
            meanProc(:,:,:,end+j) = mean(Iproc(:,:,:,bIdx(j,:)),4)./Inoise;
            meanRaw(:,:,:,end+j) = mean(Iraw(:,:,:,bIdx(j,:)),4)./Inoise;
        end
    end
    
    %   Calculate Log
    meanProc = 10*log10(meanProc);
    meanRaw = 10*log10(meanRaw);
    
    %   Create plots
    nbins = 100;
    figure;
    for j = 1:length(listBval)
        [Nproc Eproc] = histcounts(meanProc(:,:,:,meanIdx == listBval(j)),...
            nbins,'Normalization','Probability');
        [Nraw Eraw] = histcounts(meanRaw(:,:,:,meanIdx == listBval(j)),...
            nbins,'Normalization','Probability');
        IQRproc = iqr(meanProc(:,:,:,meanIdx == listBval(j)),'all');
        IQRraw = iqr(meanRaw(:,:,:,meanIdx == listBval(j)),'all');
        for k = 1:nbins
            Mproc(k) = median([Eproc(k) Eproc(k+1)]);
            Mraw(k) = median([Eraw(k) Eraw(k+1)]);
        end
        subplot(1,length(listBval),j)
        hold on;
        plot(Mproc,Nproc)
        plot(Mraw,Nraw);
        hold off;
        xlabel('SNR');
        ylabel('Normalized Voxel Count');
        legend('SNR: Designer Output','SNR: Designer Input');
        title(sprintf('B%d',listBval(j)));
        grid on; box on;
    end
    
    
    %----------------------------------------------------------------------
    %   Testing Phase
    %----------------------------------------------------------------------
    meanProc = zeros(size(Iproc,1),size(Iproc,2),size(Iproc,3),length(meanIdx));
    for j = 1:length(listBval)
        meanProc(:,:,:,meanIdx == listBval(j)) = Iproc(:,:,:,
    
    
    
    
    
    
    
end

%% PARFOR Progress Calculation
    function parProgress(~)
        if ~exist('n_completed','var')
            n_completed = 0;
        else
            n_completed = n_completed + 1;
        end
        %   Calculate percentage
        parPercentage = n_completed/nFiles*100;
        %   Update waitbar
        waitbar(n_completed/nFiles,parWaitBar,...
            sprintf('%0.1f%% completed\nHang in there...',parPercentage));
    end
end

