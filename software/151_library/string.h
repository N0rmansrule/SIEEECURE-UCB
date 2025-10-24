#ifndef STRING_H_
#define STRING_H_

#include "types.h"

int32_t strcmp(const int8_t* s0, const int8_t* s1);
uint32_t strlen(const int8_t* s);
void* memcpy(void* dest, void* src, uint32_t len);

#endif