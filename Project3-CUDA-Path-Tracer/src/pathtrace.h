#pragma once


#include <vector>
#include "scene.h"

void InitDataContainer(GuiDataContainer* guiData);
void pathtraceInit(Scene *scene);
void pathtraceFree();
void pathtrace(uchar4 *pbo, int frame, int iteration);

// Performance control functions
void toggleStreamCompaction();
void toggleMaterialSorting();
bool getStreamCompactionStatus();
bool getMaterialSortingStatus();
