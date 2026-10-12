/*  Standalone backup RAM access. See bupstandalone.h.

    Copyright 2026 YabaSanshiro contributors

    This file is part of YabaSanshiro.

    YabaSanshiro is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    YabaSanshiro is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with YabaSanshiro; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bupstandalone.h"
#include "core.h"
#include "memory.h"
#include "cs0.h"
#include "yabause.h"
#include "bios.h"
#include "sh2core.h"

/* Defined in yabause.c / bios.c, not exposed by any header. */
extern const char *bupfilename;
extern int tweak_backup_file_size;

/* Paths must stay alive for as long as the session is open, because
   bupfilename and CartridgeArea->filename keep the pointers. */
static char s_buppath[1024];
static char s_cartpath[1024];

static int s_open = 0;
static int s_cart_open = 0;

/* MappedMemoryRead/Write route cacheable addresses (the cartridge backup RAM at
   0x04000000 among them) through CurrentSH2->onchip.cache when the SH2 cache is
   compiled in. No SH2 exists in a standalone session, so a zeroed stand-in is
   installed: its cache is disabled, which makes every access take the
   non-cached path. */
static SH2_struct *s_dummy_sh2 = NULL;
static SH2_struct *s_saved_sh2 = NULL;

int YabBupStandaloneIsOpen(void) {
   return s_open;
}

static void ReleaseDummySH2(void) {
   if (s_dummy_sh2 != NULL) {
      CurrentSH2 = s_saved_sh2;
      s_saved_sh2 = NULL;
      free(s_dummy_sh2);
      s_dummy_sh2 = NULL;
   }
}

static int PrepareBackupFile(const char *buppath) {
   FILE *pbackup;
   long bupfilesize;

   pbackup = fopen_utf8(buppath, "r+b");
   if (pbackup == NULL) {
      pbackup = fopen_utf8(buppath, "w+b");
   }
   if (pbackup == NULL) {
      return -1;
   }

   fseek(pbackup, 0, SEEK_END);
   bupfilesize = ftell(pbackup);
   fseek(pbackup, 0, SEEK_SET);

   if (bupfilesize > 10 * 1024 * 1024) {
      fclose(pbackup);
      pbackup = fopen_utf8(buppath, "w+b");
      if (pbackup == NULL) {
         return -1;
      }
      FormatBackupRamFile(pbackup, tweak_backup_file_size);
   }
   else if (CheckBackupFile(pbackup) != 0) {
      FormatBackupRamFile(pbackup, tweak_backup_file_size);
   }
   else {
      ExtendBackupFile(pbackup, tweak_backup_file_size);
   }
   fclose(pbackup);
   return 0;
}

int YabBupStandaloneOpen(const char *buppath, const char *cartpath, int carttype) {
   if (s_open) {
      return -1;
   }
   if (buppath == NULL) {
      return -1;
   }
   if (strlen(buppath) >= sizeof(s_buppath)) {
      return -1;
   }
   if (cartpath != NULL && strlen(cartpath) >= sizeof(s_cartpath)) {
      return -1;
   }

   strcpy(s_buppath, buppath);
   if (cartpath != NULL) {
      strcpy(s_cartpath, cartpath);
   }
   else {
      s_cartpath[0] = '\0';
   }

   s_dummy_sh2 = (SH2_struct *)calloc(1, sizeof(SH2_struct));
   if (s_dummy_sh2 == NULL) {
      return -1;
   }
   s_saved_sh2 = CurrentSH2;
   CurrentSH2 = s_dummy_sh2;

   yabsys.extend_backup = 1;

   if (PrepareBackupFile(s_buppath) != 0) {
      ReleaseDummySH2();
      return -1;
   }

   bupfilename = s_buppath;
   BupRam = (u8 *)YabMemMap(s_buppath, (u32)tweak_backup_file_size);
   if (BupRam == NULL) {
      ReleaseDummySH2();
      return -1;
   }
   BupRamWritten = 0;

   /* CartInit installs the Cs0/Cs1 handlers that MappedMemoryInit needs,
      so it must run first even when there is no cartridge. */
   if (CartInit(s_cartpath, carttype) != 0) {
      CartDeInit();
      YabFreeMap(BupRam);
      BupRam = NULL;
      ReleaseDummySH2();
      return -1;
   }
   s_cart_open = 1;

   MappedMemoryInit();

   s_open = 1;
   return 0;
}

void YabBupStandaloneClose(void) {
   if (!s_open) {
      return;
   }

   if (BupRam != NULL) {
      YabFlushMemMap(BupRam);
      YabFreeMap(BupRam);
      BupRam = NULL;
   }

   if (s_cart_open) {
      CartFlush();
      CartDeInit();
      s_cart_open = 0;
   }

   ReleaseDummySH2();

   s_open = 0;
}

/* Replica of the month/day conversion in bios.c ConvertMonthAndDayMem.
   Kept here rather than shared so this file adds nothing to the existing
   code paths; the round trip test proves the two agree. The 0xFF masks
   mirror the (u8) casts the original performs when storing the results. */
static void DecodeMonthAndDay(unsigned int data, int *month, int *day, int type) {
   int i;
   const unsigned short monthtbl[11] = {
      31, 31+28, 31+28+31, 31+28+31+30, 31+28+31+30+31,
      31+28+31+30+31+30, 31+28+31+30+31+30+31,
      31+28+31+30+31+30+31+31, 31+28+31+30+31+30+31+31+30,
      31+28+31+30+31+30+31+31+30+31,
      31+28+31+30+31+30+31+31+30+31+30 };

   if (data < monthtbl[0]) {
      *month = 1;
      *day = (int)((data + 1) & 0xFF);
      return;
   }

   for (i = 1; i < 11; i++) {
      if (data <= monthtbl[i]) {
         break;
      }
   }

   *month = (i + 1) & 0xFF;
   if (type == 1) {
      if ((i + 1) == 2) {
         *day = (int)((data - monthtbl[i - 1] + 1) & 0xFF);
      } else {
         *day = (int)((data - monthtbl[i - 1]) & 0xFF);
      }
   } else {
      *day = (int)((data - monthtbl[i - 1] + 1) & 0xFF);
   }
}

void YabBupDecodeDate(unsigned int date, int *year, int *month, int *day,
                      int *hour, int *minute) {
   unsigned int div;
   unsigned int yearremainder;
   unsigned int yearoffset;
   int m = 0;
   int d = 0;

   if (hour != NULL) {
      *hour = (int)((date % 0x5A0) / 0x3C);
   }
   if (minute != NULL) {
      *minute = (int)(date % 0x3C);
   }

   div = date / 0x5A0;
   yearremainder = div % 0x5B5;

   if (yearremainder > 0x16E) {
      yearoffset = (yearremainder - 1) / 0x16D;
      DecodeMonthAndDay((yearremainder - 1) % 0x16D, &m, &d, 0);
   } else {
      yearoffset = 0;
      DecodeMonthAndDay(yearremainder - 1, &m, &d, 1);
   }

   if (year != NULL) {
      *year = 1980 + (int)((((div / 0x5B5) * 4) + yearoffset) & 0xFF);
   }
   if (month != NULL) {
      *month = m;
   }
   if (day != NULL) {
      *day = d;
   }
}

unsigned int YabBupEncodeDate(int year, int month, int day, int hour, int minute) {
   /* The decoding is not a simple formula, so rather than inverting it by
      hand (which is easy to get subtly wrong) search for the day count that
      decodes back to the requested date. */
   unsigned int div;
   unsigned int timepart;
   const unsigned int maxdiv = 50000;

   if (year < 1980 || month < 1 || month > 12 || day < 1 || day > 31) {
      return 0;
   }
   if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return 0;
   }

   timepart = (unsigned int)(hour * 0x3C + minute);

   for (div = 0; div < maxdiv; div++) {
      int y = 0;
      int m = 0;
      int d = 0;
      YabBupDecodeDate(div * 0x5A0, &y, &m, &d, NULL, NULL);
      if (y == year && m == month && d == day) {
         return div * 0x5A0 + timepart;
      }
   }
   return 0;
}
