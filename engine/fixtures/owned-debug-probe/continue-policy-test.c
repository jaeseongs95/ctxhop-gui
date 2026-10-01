#include <stdio.h>
#include "continue-policy.h"

int main(void)
{
    unsigned slot, bits, checks = 0;
    /* Fixed truth table: known slots allow 3,6,7,8..15; slot2 only 8..15. */
    const unsigned allowed[3] = {0xffc8, 0xffc8, 0xff00};
    for (slot = 0; slot < 3; ++slot) {
        for (bits = 0; bits < 16; ++bits) {
            int validated = !!(bits & 1), member = !!(bits & 2);
            int jobAccepted = !!(bits & 4), exactAccepted = !!(bits & 8);
            int expected = !!(allowed[slot] & (1u << bits));
            int actual = can_continue_create(slot, validated, member, jobAccepted, exactAccepted);
            printf("{\"slot\":%u,\"validated\":%d,\"currentMember\":%d,"
                   "\"jobTerminationAccepted\":%d,\"exactTerminationAccepted\":%d,"
                   "\"allowed\":%d,\"expected\":%d}\n",
                   slot, validated, member, jobAccepted, exactAccepted, actual, expected);
            if (actual != expected) return 1;
            ++checks;
        }
    }
    printf("{\"checks\":%u,\"actualProbe\":0,\"targetLaunches\":0}\n", checks);
    return checks == 48 ? 0 : 1;
}
