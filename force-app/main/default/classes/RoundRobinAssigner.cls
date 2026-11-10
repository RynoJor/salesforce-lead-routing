/**
 * Round-robin within a pool, skipping reps at capacity. Pure logic, no SOQL or DML, so the
 * service loads state once per transaction and this class works on it in memory.
 *
 * load:     open leads per rep, counted before the batch and incremented as leads are assigned
 * cursor:   pool key -> index of the next rep to try
 * capacity: max open leads per rep
 */
public with sharing class RoundRobinAssigner {
    public class Pick {
        public Id ownerId;
        public Integer skipped; // reps passed over because they were full
        public Pick(Id ownerId, Integer skipped) {
            this.ownerId = ownerId;
            this.skipped = skipped;
        }
    }

    private Map<Id, Integer> load;
    private Map<Id, Integer> capacity;
    public Map<String, Integer> cursor { get; private set; }

    public RoundRobinAssigner(Map<Id, Integer> load, Map<Id, Integer> capacity, Map<String, Integer> cursor) {
        this.load = load == null ? new Map<Id, Integer>() : load;
        this.capacity = capacity == null ? new Map<Id, Integer>() : capacity;
        this.cursor = cursor == null ? new Map<String, Integer>() : cursor;
    }

    /**
     * Next rep in the pool with room, or null if the pool is empty or every rep is full.
     * `poolCapacity` applies to reps with no capacity of their own.
     */
    public Pick assign(String poolKey, List<Id> pool, Integer poolCapacity) {
        if (pool == null || pool.isEmpty()) {
            return null;
        }
        Integer size = pool.size();
        Integer start = cursor.containsKey(poolKey) ? Math.mod(cursor.get(poolKey), size) : 0;
        for (Integer step = 0; step < size; step++) {
            Integer i = Math.mod(start + step, size);
            Id rep = pool[i];
            if (loadOf(rep) < capacityOf(rep, poolCapacity)) {
                cursor.put(poolKey, Math.mod(i + 1, size));
                take(rep);
                return new Pick(rep, step);
            }
        }
        return null;
    }

    /** Count a lead against a rep (also used when a duplicate goes to its existing owner). */
    public void take(Id rep) {
        load.put(rep, loadOf(rep) + 1);
    }

    public Integer loadOf(Id rep) {
        return load.containsKey(rep) ? load.get(rep) : 0;
    }

    private Integer capacityOf(Id rep, Integer poolCapacity) {
        if (capacity.containsKey(rep) && capacity.get(rep) != null) {
            return capacity.get(rep);
        }
        return poolCapacity == null ? 0 : poolCapacity;
    }
}
