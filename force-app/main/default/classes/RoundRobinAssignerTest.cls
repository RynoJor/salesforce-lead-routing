@IsTest
private class RoundRobinAssignerTest {
    // Fake user Ids: the assigner never queries them.
    private static final Id A = '005000000000001';
    private static final Id B = '005000000000002';
    private static final Id C = '005000000000003';

    @IsTest
    static void rotatesThroughThePool() {
        RoundRobinAssigner rr = new RoundRobinAssigner(null, null, null);
        List<Id> pool = new List<Id>{ A, B, C };
        List<Id> picks = new List<Id>();
        for (Integer i = 0; i < 4; i++) {
            picks.add(rr.assign('P', pool, 10).ownerId);
        }
        Assert.areEqual(new List<Id>{ A, B, C, A }, picks);
        Assert.areEqual(1, rr.cursor.get('P'));
        Assert.areEqual(2, rr.loadOf(A));
    }

    @IsTest
    static void skipsFullRepsAndReportsTheSkip() {
        RoundRobinAssigner rr = new RoundRobinAssigner(
            new Map<Id, Integer>{ A => 5 },
            new Map<Id, Integer>{ B => 0 },
            new Map<String, Integer>{ 'P' => 0 }
        );
        RoundRobinAssigner.Pick pick = rr.assign('P', new List<Id>{ A, B, C }, 5);
        Assert.areEqual(C, pick.ownerId, 'A is at pool capacity, B has a personal cap of 0');
        Assert.areEqual(2, pick.skipped);
    }

    @IsTest
    static void returnsNullWhenEveryoneIsFullOrPoolIsEmpty() {
        RoundRobinAssigner rr = new RoundRobinAssigner(new Map<Id, Integer>{ A => 3 }, null, null);
        Assert.isNull(rr.assign('P', new List<Id>{ A }, 3));
        Assert.isNull(rr.assign('P', new List<Id>(), 3));
        Assert.isNull(rr.assign('P', null, 3));
        Assert.isNull(rr.assign('P', new List<Id>{ B }, null), 'No capacity set means no room');
    }
}
