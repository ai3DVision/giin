% Retrieve the missing pixels of an image.
% The goal of this script is to inpaint the missing pixels of an image. It
% does so by constructing a patch graph of the known pixels. According to
% some priority, it then iteratively connect unknown patches to the graph.
% A global optimization is run in the end.

close all; clear; clc;
gsp_start();

% Experiment parameters.
imtype = 'lena3'; % Type of line.
imsize = 100; % Image size.
holesize = 20; % Hole size.
plot = true;
savefig = false;

% Algorithm parameters.
gparam.graph.psize = 5; % Patch size.
gparam.graph.knn = 10; % Patch graph minimum number of connections (KNN).
gparam.graph.sigma = 1e-8; % Variance of the distance kernel. We want the graph weights to be well spread.
gparam.graph.loc = 0.001; % Importance of local information. (default 0.001, 0.1)
gparam.connect.max_unknown_pixels = gparam.graph.psize; % Maximum number of unknown pixels to connect a patch.
gparam.priority.threshold = 1e-3; % Threshold when creating priority from diffused energy.
gparam.priority.heat_scale = 50; % Depends on sigma. 1000 for lena
gparam.priority.cheb_order = 30; % Order of the Chebyshev approximation (number of hopes).
gparam.inpainting.retrieve = 'copy'; % Average connected patches or copy the strongest.
gparam.inpainting.compose = 'overwrite'; % Keep known pixels or overwrite everything.
gparam.optim.prior = 'thikonov'; % Global optimization constraint : thikonov or tv.
gparam.optim.maxit = 100; % Maximum number of iterations.
gparam.optim.sigma = 0; % Noise level.

%% Image

[img, obsimg, vertices] = giin_image(imtype, imsize, holesize);
clear imtype holesize

%% Patch graph
% Unknown patches are disconnected.

tic;

% We want some local information for the spatially close patches to be
% connected in case of large uniform surfaces.
param.rho = gparam.graph.loc;

param.patch_size = gparam.graph.psize;
param.nnparan.center = 0;
param.nnparam.resize = 0;
param.nnparam.k = gparam.graph.knn;
param.nnparam.sigma = gparam.graph.sigma;
[G, pixels, patches] = gsp_patch_graph(obsimg, param);

% Execution time.
fprintf('Time to create graph : %f seconds\n', toc);

if plot
    figure();
    hist(G.W(:), -.05:.1:1);
    xlim([eps,1]);
    title(['Graph weights distribution, \sigma=',num2str(gparam.graph.sigma)]);
end

clear param

% Visualize a patch : reshape(patches(4380,1:end-2),psize,psize)

%% Visualize graph with image signal

if plot
    % Signal graph.
    fig = figure(); %#ok<UNRCH>

    % Any negative value is a missing pixel --> red.
    cmap = [1,0,0;gray];
    colormap(fig, cmap);
    param.climits = [-1/(length(cmap)-1),1];
    
    param.colorbar = 0;
%     param.vertex_highlight = connected; % draw by hand in different colors instead
%     param.show_edges = true; % very slow

    gsp_plot_signal(G, pixels, param);
    if savefig, saveas(gcf,['results/',imtype,'_patch_graph.png']); end

    clear param fig cmap
end

%% Iterative inpainting

tstart = tic;

% Each unknown pixel has a value of -1e3. A patch with 4 unknown pixels
% will end up with a value of -4. The minimum is -psize^2.
unknowns = (patches<0) .* patches;
unknowns = sum(unknowns,2) / 1000;

% List of new vertices considered for inpainting.
% news = find(unknowns<0).';
currents = [];
inpainted = [];

% Patches which contain no other information than their position cannot be
% connected in the non-local graph.

fprintf('There is %d incomplete patches :\n', sum(unknowns<0));
fprintf('  %d without any information\n', sum(unknowns==-gparam.graph.psize^2));
% fprintf('  %d considered for inpainting\n', length(news));

% List of fully known patches to which we can connect.
knowns = find(unknowns==0);
if sum(unknowns<0)+length(knowns) ~= G.N
    error('Missing vertices !');
end

% Structure priority.
Pstructure = nan(G.N, 1);

% Information priority. First column is pixels priority, second is patches.
Pinformation(:,1) = double(pixels>0);
Pinformation(:,2) = nan(G.N,1);
patch_pixels = giin_patch_vertices('pixels', gparam.graph.psize, imsize);
for patch = find(unknowns<0).'
    Pinformation(patch,2) = mean(Pinformation(patch+patch_pixels,1));
end

% currents  : vertices to be inpainted
% news      : vertices to be connected, i.e. newly considered pixels
% inpainted : vertices already inpainted, to avoid an infinite loop

% Until no more vertices to inpaint.
first = true;
while ~isempty(currents) || first
    first = false;
    
    % Each unknown pixel has a value of -1e3. A patch with 4 unknown pixels
    % will end up with a value of -4. The minimum is -psize^2.
    unknowns = (patches<0) .* patches;
    unknowns = sum(unknowns,2) / 1000;
    
    news = find(unknowns<0).';

    % We only consider patches with less than some number of missing pixels.
    news = news(unknowns(news)>=-gparam.connect.max_unknown_pixels);
    % Which are not already connected.
    news = news(~ismember(news, currents));
    % Neither already visited (to prevent infinite loop and reconnections).
    news = news(~ismember(news, inpainted));
    currents = [currents, news]; %#ok<AGROW>

    if any(ismember(currents, inpainted))
        error('A vertex could be visited again !');
    end
    
    % What if some patch has no more unknown pixels ?
    % Do we always inpaint over ?

    % Connect the newly reachable vertices.
    G = giin_connect(G, news, knowns, patches, gparam);

    % Compute their priorities, i.e. update the priority signal.
    Pstructure = giin_priorities(news, Pstructure, G, gparam);

    % TODO: we also need to take into account the data priority, and normalize
    % the two to give them the same weight.

    % Highest priority patch. Negate the value so that it won't be selected
    % again while we keep the information ([0,1] --> [-1,-2]).
    [~,vertex] = max(Pstructure .* Pinformation(:,2));
    Pstructure(vertex) = -1-Pstructure(vertex);

    % Update pixels and patches.
    [pixels, patches, Pinformation, ~] = giin_inpaint(vertex, G, pixels, patches, Pinformation, gparam);

    % Remove the currently impainted vertex from the lists.
%     news = news(news~=vertex);
    currents = currents(currents~=vertex);
    inpainted = [inpainted, vertex]; %#ok<AGROW>
    
    % Live plot.
    if plot
        figure(10); %#ok<UNRCH>
        width = max(G.coords(:,1));
        height = max(G.coords(:,2));
        imshow(reshape(pixels,height,width), 'InitialMagnification',600);
        drawnow;
    end

    fprintf('Inpainted vertices : %d (%d waiting)\n', length(inpainted), length(currents));
end

% Restore priorities.
Pstructure = -1-Pstructure;

% Execution time
fprintf('Iterative inpainting : %f\n', toc(tstart));

clear unknowns news currents vertex first knowns tstart

%% Visualize priorities

if plot
    % Show some vertices of interest.
    giin_plot_priorities(vertices, G, gparam, savefig);
    
    % Plot the various priorities.
    figure();
    subplot(2,2,1);
%     imshow(imadjust(reshape(Pstructure,imsize,imsize)));
    imshow(reshape(Pstructure,imsize,imsize) / max(Pstructure));
    title('Structure priority');
    subplot(2,2,2);
    imshow(reshape(Pinformation(:,1), imsize, imsize));
    title('Pixel infomation priority');
    subplot(2,2,4);
    imshow(reshape(Pinformation(:,2), imsize, imsize));
    title('Patch infomation priority');
    subplot(2,2,3);
    imshow(reshape(Pstructure .* Pinformation(:,2), imsize, imsize) / max(Pstructure .* Pinformation(:,2)));
    title('Global priority');
    colormap(hot);
end

%% Global stage by convex optimization
% Now we inpaint again the image using the created non-local graph.

init_unlocbox();
verbose = 1;

% Observed signal (image).
M = reshape(obsimg>=0, [], 1);
y = M .* reshape(img, [], 1);

% Data term.
% fdata.grad = @(x) 2*M.*(M.*x-y);
% fdata.eval = @(x) norm(M.*x-y)^2;
param_b2.verbose = verbose -1;
param_b2.y = y;
param_b2.A = @(x) M.*x;
param_b2.At = @(x) M.*x;
param_b2.tight = 1;
param_b2.epsilon = gparam.optim.sigma*sqrt(sum(M(:)));
fdata.prox = @(x,T) proj_b2(x,T,param_b2);
fdata.eval = @(x) eps;

% Prior.
param_prior.verbose = verbose-1;
switch(gparam.optim.prior)
    
    % Thikonov prior.
    case 'thikonov'
        fprior.prox = @(x,T) gsp_prox_tik(x,T,G,param_prior);
        fprior.eval = @(x) gsp_norm_tik(G,x);
    
    % TV prior.
    case 'tv'
        G = gsp_adj2vec(G);
        G = gsp_estimate_lmax(G);
        fprior.prox = @(x,T) gsp_prox_tv(x,T,G,param_prior);
        fprior.eval = @(x) gsp_norm_tv(G,x);
end

% Solve the convex optimization problem.
param_solver.verbose = verbose;
param_solver.tol = 1e-7;
param_solver.maxit = gparam.optim.maxit;
tic;
[sol, info] = douglas_rachford(y,fprior,fdata,param_solver);

% Execution time.
fprintf('Global optimization : %f (%d iterations)\n', toc, info.iter);

clear verbose M fdata fprior param_b2 param_prior param_solver info

%% Results

% Images.
figure();
subplot(2,2,1);
imshow(img);
title('Original');
subplot(2,2,2);
imshow(reshape(y,imsize,imsize));
title('Masked');
subplot(2,2,3);
imshow(reshape(pixels,imsize,imsize));
title('Inpainted');
subplot(2,2,4);
imshow(reshape(sol,imsize,imsize));
title(['Globally optimized (',gparam.optim.prior,')']);
saveas(gcf,'results/inpainting_last.png');

% Reconstruction errors.
fprintf('Observed image error (L2-norm) : %f\n', norm(reshape(img,[],1) - y));
fprintf('Inpainting reconstruction error : %f\n', norm(reshape(img,[],1) - pixels));
fprintf('Globally optimized reconstruction error : %f\n', norm(reshape(img,[],1) - sol));