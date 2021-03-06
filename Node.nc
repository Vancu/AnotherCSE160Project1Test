/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
//#include "includes/LSP.h"
//Struct for Neighbor which houses NODE ID AND NumofPings
typedef nx_struct LinkedNeighbor {
	//Node ID and Number of Pings is Stored. This is how we determine the age of the neighbor
	nx_uint16_t Node_ID;
	nx_uint8_t NumofPings;
}LinkedNeighbor;

typedef nx_struct RoutedTable {
        //Node ID and Number of Pings is Stored. This is how we determine the age of the neighbor
        nx_uint16_t Node_ID;
        nx_uint8_t Cost;
	nx_uint8_t Next;
	nx_uint8_t sequence;
}RoutedTable;

module Node{
   uses interface Boot;
   uses interface Timer<TMilli> as periodicTimer; //Interface that was wired above.
   
   //uses interface Timer<TMilli> as LSP_Timer; //Interface that was wired above.
   //List of packs to store the info of identified packets, along if we've seen it or not  
   uses interface List<pack> as PacketStorage;   

   //List of structs that holds both Node ID and amount of times pinged to keep track of the neighbors, neighbor will be dropped if number of pings gets too large
   uses interface List<LinkedNeighbor > as NeighborStorage;
   
   //List of structs that holds the LinkedNeighbors that ended up being dropped from NeighborStorage
   uses interface List<LinkedNeighbor > as NeighborsDropped;
   
   uses interface SplitControl as AMControl;

   // Flooding Portion
   uses interface Receive;
   uses interface SimpleSend as Sender;


   uses interface CommandHandler;
   uses interface Random as Random;
   uses interface List<RoutedTable  > as RoutedTableStorage;
}

//These are stored in each node
implementation{
   pack sendPackage;
   uint16_t sequence = 0;
   //uint16_t CostCount = 0;
   uint16_t LSP_Limit = 0;
   // Prototypes (aka function definitions that are exclusively in this implimentation
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   //Handles new seen and sent packs by storing into the specific Node's List<pack> named PacketStorage for flooding and List<LinkedNeighbor > for NeighborStorage and NeighborDropped 
   void pushPack(pack Package); 
  
   //Checks to see if the pack has already been received. Alterations can occur if the SeqNum is different. 
   bool DupliPack(pack *Package);

   //Look through our NeighborList to see if it's a new neighbor or not
   void findNeighbor();

   //Look through our network and calculate a cost to reach that path
   void findRoute();

   event void Boot.booted(){
      uint32_t begin, timeDifference;    
      uint16_t sign;     

      //Begin is determine how much milliseconds after Boot is called to start firing, which is between 0 to 3.5 seconds
      begin = call Random.rand32() % 3500;

      //To make it more random by determining if you add or subtract from a giving timeDifference, where timeDifference determines how often 
      //Node is fired, which is set to be from 15.5 seconds to 24.5 seconds.
      sign = call Random.rand16() % 2;

      timeDifference = 20000;
      if (sign == 1)
      	    timeDifference += call Random.rand16() % 4500; 
      
      else
   	    timeDifference -= call Random.rand16() % 4500;	

      call AMControl.start();

      call periodicTimer.startPeriodicAt(begin, timeDifference);

      //The reason why we want to fire every now and then is because we don't want the network to constantly be dropping packets because another
      //node is firing at the same time. We want them to be discovering their neighbors at a logical timeframe
      //dbg(GENERAL_CHANNEL, "Booted with the beginning time starting at %d, periodic call fired every %d milliseconds. RouteTimeCheck set to %d ms\n", begin, timeDifference, RouteTimeCheck);
      //dbg(GENERAL_CHANNEL, "Booted Successfully!");
  }


   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event void periodicTimer.fired() 
	{
		//dbg(GENERAL_CHANNEL, "I'm going to fire a findNeighbor() function\n");
		findNeighbor();
		if (LSP_Limit % 2 == 1 && LSP_Limit > 1)
              		findRoute();
	}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
  	//dbg(FLOODING_CHANNEL, "Packet Received\n"); 
      	if(len==sizeof(pack))
	{
		//Creates a pack datatype which takes in from void* payload.
        	pack* myMsg=(pack*) payload;

		//Check to see if we've already received/seen this node already or if the TTL is 0
		if (myMsg->TTL == 0 || DupliPack(myMsg))
		{
			//dbg(FLOODING_CHANNEL, "Recieved packet that has no more TTL OR Node has already seen it, lets drop this packet...\n");
			//dbg(FLOODING_CHANNEL, "TTL: %d,   src: %d,    dest: %d,   seq: %d\n", myMsg->TTL, myMsg->src, myMsg->dest, myMsg->seq);
			//return msg;
		}
		
		//Check to see if this is a packet for calculating routing table
		else if(myMsg->dest == AM_BROADCAST_ADDR && myMsg->protocol == PROTOCOL_LINKSTATE)
		{
			RoutedTable PartialTable;
                	//uint16_t m = 0;
			pack ForwardedNeighborRoute;
			//We will compare the Packet's NeighborList as it represents the source's list of neighbors with the current node's 
			//list of neighbors.
			uint16_t i, k, true, RealCost = -1;
			//uint16_t Table_Length = call RoutedTableStorage.size();
			//uint16_t NodeNeighborLength = call NeighborStorage.size();
			//LinkedNeighbor NeighborfromNode;
			uint16_t CostCount = MAX_TTL - myMsg->TTL;
			//Here, we want to check the Packet's List of Neighbors 
			//and compare with Node's List of Neighbors.
			//
			
			//dbg(ROUTING_CHANNEL, "Node: %d Has successfully received an LSP Packet from Node %d! CostCount: %d \n", TOS_NODE_ID, myMsg->src, CostCount);
			//dbg(ROUTING_CHANNEL, "Payload's Array length is: %d \n", call RoutedTableStorage.size());
			for(i = 0; i < call RoutedTableStorage.size(); i++)
			{	
				true = 0;		
				if (myMsg->payload[i] <= 0)
                                { 
					break;
				}
				//dbg(ROUTING_CHANNEL, "Payload's Array Index %d Has Neighbor: %d \n",i, myMsg->payload[i]);
		
				for(k = 0; k < call RoutedTableStorage.size(); k++)
				{
					PartialTable = call RoutedTableStorage.get(k);
					if (myMsg->payload[i] == PartialTable.Node_ID || TOS_NODE_ID == myMsg->payload[i])
					{	
						//if(PartialTable.Cost < CostCount )
						//{
							//RoutedTable removeLinked;
			                                //removeLinked = call RoutedTableStorage.removefromList(k);
        	                        		//dbg(ROUTING_CHANNEL, "Supposedly found an equal and going to drop it because the cost is lower\n");
                	                		//call NeighborsDropped.pushfront(NeighborNode);
                        			        //k--;
                        			        //Table_Length--;
							//dbg(ROUTING_CHANNEL, "WE FOUND A MATCH, MARK TRUE AND WE SUPPOSEDLY IGNORE IT \n");
							true++;
							//break; 
						//}
						//else
						//{
						 	//true++;
                                                        //break;
						//}
					}
				}
				//i++;
				if (true == 0)
				{
					RoutedTable UndescoveredNeighbor;
					UndescoveredNeighbor.Node_ID = myMsg->payload[i];
					
					//dbg(ROUTING_CHANNEL, "Payload is: %d      while myMsg->src is: %d \n", myMsg->payload[i], myMsg->src);
					//dbg(ROUTING_CHANNEL, "myMsg->payload[i] - TOS_NODE_ID is: %d \n", myMsg->payload[i] - TOS_NODE_ID );					
					//	if (myMsg->payload[i] - TOS_NODE_ID == 1)
					//		UndescoveredNeighbor.Cost = CostCount + 1;
					//	else if (myMsg->payload[i] - myMsg->src == -1) 
					//		UndescoveredNeighbor.Cost = CostCount - 1;
					//	else
					//		UndescoveredNeighbor.Cost = 0;
			
					//dbg(ROUTING_CHANNEL, "Payload for determining cost is: %d \n", myMsg->payload[i]);
					RealCost = myMsg->payload[i] - TOS_NODE_ID;
					//dbg(ROUTING_CHANNEL, "before RealCost: %d \n", RealCost);
					if (myMsg->payload[i] - TOS_NODE_ID < 0)
						RealCost = TOS_NODE_ID - myMsg->payload[i];
                                        
					//dbg(ROUTING_CHANNEL, "After RealCost: %d \n", RealCost); 
					//UndescoveredNeighbor.Cost = CostCount + 1;
                                        UndescoveredNeighbor.Cost = RealCost;
					UndescoveredNeighbor.Next = myMsg->src;
                                        call RoutedTableStorage.pushback(UndescoveredNeighbor);
				}	  			
			}

        	//dbg(ROUTING_CHANNEL, "We checked all of LSP's directly connected neighbors. Printing out the table so far \n");
        	//dbg(ROUTING_CHANNEL, "----------Node %d's Table--------- \n", TOS_NODE_ID);
        	//while(m < call RoutedTableStorage.size())
        	//{       
                	//PartialTable = call RoutedTableStorage.get(m); 
                	//dbg(ROUTING_CHANNEL, "Node_ID: %d  Cost: %d    Next:%d \n", PartialTable.Node_ID, PartialTable.Cost, PartialTable.Next);
                	//m++;
        	//}

		
                makePack(&ForwardedNeighborRoute, TOS_NODE_ID, AM_BROADCAST_ADDR, myMsg->TTL - 1, PROTOCOL_LINKSTATE, myMsg->seq, (uint8_t*) myMsg->payload, (uint8_t) sizeof(myMsg->payload));
                pushPack(ForwardedNeighborRoute);
		call Sender.send(ForwardedNeighborRoute, AM_BROADCAST_ADDR);


			
		}


		//HERE, CHECK TO SEE IF THIS IS A PACKET CHECKING FOR ITS NEIGHBORS, THIS IS SEPARATE FROM FLOODING
	        else if(myMsg->dest == AM_BROADCAST_ADDR && (myMsg->protocol == PROTOCOL_PING || myMsg->protocol == PROTOCOL_PINGREPLY))
        	{
	        	uint16_t length, i = 0;
        		LinkedNeighbor Neighbor, Neighbor2;
            		bool found = FALSE; 
            		if (myMsg->protocol == PROTOCOL_PING)
            		{
                		//Here, we want to check if the node who sent the packet to this node are neighbors, so instead of broadcasting it like we normally do,
                		//we send back to the source to confirm if they're neighbors or not.   
                		//dbg(NEIGHBOR_CHANNEL, "Packet %d wants to check for its neighbors\n", myMsg->src);
               			makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, myMsg->TTL--, PROTOCOL_PINGREPLY, myMsg->seq, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
                		pushPack(sendPackage);
                		call Sender.send(sendPackage, myMsg->src);
				//dbg(NEIGHBOR_CHANNEL, "Does it crash after make,push and send?...\n");
            		}	
             
            		//Here, we get a ping reply, check to see if the neighbor already exist in the specific Node's Neighbor Storage
           		//If we do find a match, mark it as true as it will be handled at the bottom
            		else if (myMsg->protocol == PROTOCOL_PINGREPLY)
            		{       
               			//dbg(GENERAL_CHANNEL, "Packet Receive from %d, replying\n", myMsg->src);
               			length = call NeighborStorage.size();
               			//Here is where found = FALSE;
               			for(i = 0; i < length; i++)
     	          		{       
        	        		Neighbor2 = call NeighborStorage.get(i);
                	  		if(Neighbor2.Node_ID == myMsg->src)
                  			{       
                     				Neighbor2.NumofPings = 0;
                    				found = TRUE;
                  			}
               			}
            		}
             
           		//If we didn't find it as a neighbor, then we need to add it to the node's NeighborStorage
	   		if (!found)
            		{       
       				//add it to the list, using the memory of a previous dropped node
			
				//found = FALSE;
				Neighbor = call NeighborsDropped.get(0);
				//check to see if already in list
				length = call NeighborStorage.size();
				for (i = 0; i < length; i++)
				{
					Neighbor2 = call NeighborStorage.get(i);
					if (myMsg->src == Neighbor2.Node_ID)
					{
						found = TRUE;
					}
				}
				if (found) 
				{
					//already in the list, no need to repeat
				}
				else 
				{
					RoutedTable ImmediateNeighbor;
					//not in list, so we're going to add it
					//dbg(NEIGHBOR_CHANNEL, "%d not found, put in list\n", myMsg->src);
					Neighbor.Node_ID = myMsg->src;
					Neighbor.NumofPings = 0;
					found = FALSE;
					call NeighborStorage.pushback(Neighbor);
					
					for(i = 0; i < call RoutedTableStorage.size(); i++)
                        		{
						ImmediateNeighbor = call RoutedTableStorage.get(i);
                                        	if (myMsg->src == ImmediateNeighbor.Node_ID)
                                        	{
							found = TRUE;
						}	
					}
					if (!found)				
					{
						ImmediateNeighbor.Node_ID = myMsg->src;
						ImmediateNeighbor.Cost = 1;
						ImmediateNeighbor.Next = myMsg->src;
						ImmediateNeighbor.sequence = 0;
						call RoutedTableStorage.pushback(ImmediateNeighbor); 
					}
				}
			}
			
			//This means that the Neighbor exists in the Neighbor List
                
        	}	

	
	//Check the packet to see if the packet received is meant for the node
	else if(myMsg->dest == TOS_NODE_ID && myMsg->protocol == PROTOCOL_PING)
	{
        	dbg(FLOODING_CHANNEL, "Received packet from %d has arrived! Package Payload: %s\n",myMsg->src, myMsg->payload);
		dbg(FLOODING_CHANNEL, "Sending the ACK packet to Node: %d...\n", myMsg->src);
			
		//Hooray! We've successfuly delivered the packet. Now we have to send a ping reply to the initial source

		//Before we make an ACK packet, increment sequence by 1 since it's a different packet and push a newly created ACK packet to the list PacketStorage
                //then broadcast to it's neighbors.
                sequence++;

 
		//Lets make the ACK packet by having the TOS_NODE_ID be the source and the destination be the source, and changing the protocol to be PINGREPLY 
		makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, sequence, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE); 
		
		pushPack(sendPackage);
		//dbg(GENERAL_CHANNEL, "pushPack was successful\n");
		call Sender.send(sendPackage, AM_BROADCAST_ADDR);
		//dbg(GENERAL_CHANNEL, "Call Sender was successful\n");
		//return msg;
	}
        else if(myMsg->dest == TOS_NODE_ID && myMsg->protocol == PROTOCOL_PINGREPLY)
	{
         	dbg(FLOODING_CHANNEL, "Received ACK packet from %d, where that was the original destination.\n", myMsg->src);
		//dbg(FLOODING_CHANNEL, "Recieved packet, STATS... Payload: %s\n", myMsg->payload);
		//return msg;
		sequence++;
	}	

	//Packet not meant for it, decrement TTL, mark it as seen after making a new pack, and broadcast to neighhors
	else
	{
		//dbg(FLOODING_CHANNEL, "Recieved packet, It's not for it... TTL: %d,   src: %d,    dest: %d,   seq: %d\n", myMsg->TTL, myMsg->src, myMsg->dest, myMsg->seq);
		makePack(&sendPackage, (myMsg->src), (myMsg->dest), (myMsg->TTL--), (myMsg->protocol), (myMsg->seq), ((uint8_t *)myMsg-> payload), PACKET_MAX_PAYLOAD_SIZE);
		pushPack(sendPackage);
		call Sender.send(sendPackage, AM_BROADCAST_ADDR);
		//return msg;
	}

	return msg;

      } 
	else
	{	
      		dbg(FLOODING_CHANNEL, "Unknown Packet Type %d\n", len);
      		return msg;
	}
   }
	


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload)
{
	dbg(GENERAL_CHANNEL, "PING EVENT \n");
      	makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, sequence, payload, PACKET_MAX_PAYLOAD_SIZE);
      	call Sender.send(sendPackage, AM_BROADCAST_ADDR);
     	//dbg(GENERAL_CHANNEL, "RESETTING foundPack BOOL \n");
}

   event void CommandHandler.printNeighbors(){
	uint16_t i, size = call NeighborStorage.size();
	LinkedNeighbor printedNeighbor;
	//Print out NeighborList after updating
	
	if(size == 0)
 	{
		dbg(GENERAL_CHANNEL, "No Neighbors found in Node %d\n", TOS_NODE_ID);
	}
	
	 else 
	{
		//dbg(GENERAL_CHANNEL, "Dumping neighbor list for Node %d\n", size, TOS_NODE_ID);
		for(i = 0; i < size; i++) 
		{
			printedNeighbor = call NeighborStorage.get(i);
			dbg(GENERAL_CHANNEL, "Neighbor: %d, NumofPings: %d\n", printedNeighbor.Node_ID, printedNeighbor.NumofPings);
		}
	}

}

   event void CommandHandler.printRouteTable()
{

}

   event void CommandHandler.printLinkState()
{
        RoutedTable PartialTable;
        uint16_t m = 0;
        dbg(ROUTING_CHANNEL, "We checked all of LSP's directly connected neighbors. Printing out the table so far \n");
        dbg(ROUTING_CHANNEL, "----------Node %d's Table--------- \n", TOS_NODE_ID);
        while(m < call RoutedTableStorage.size())
        {
                PartialTable = call RoutedTableStorage.get(m);
                dbg(ROUTING_CHANNEL, "Node_ID: %d  Cost: %d    Next:%d \n", PartialTable.Node_ID, PartialTable.Cost, PartialTable.Next);
                m++;
        }
}

   event void CommandHandler.printDistanceVector()
{
  
}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);   
      }

   //This searchPack is specific to a single node. This is also enabling for when this node recieves the same packet from a different 
   bool DupliPack (pack *Package)
   {
   	uint16_t sizeofList = call PacketStorage.size();
 	uint16_t i = 0;
	pack CheckPack;
	for(i = 0; i < sizeofList; i++)
 	{
		//dbg(GENERAL_CHANNEL, "The searchPack loop is going... \n");
		//Go through each packet that's in the list to see if we've discovered it already
		CheckPack = call PacketStorage.get(i);
		
		//Checking for sequence number is important for determining if it's a ping reply or not


		if (CheckPack.src == Package->src && CheckPack.dest == Package->dest && CheckPack.seq == Package->seq)
		{
			//We've discovered this packet already, so go ahead and send the signal to be used later to drop the packet
			return TRUE;
		}
	}
	return FALSE;	
    }

   //We're checking to see if it's full, then to make room since we're dealing with static memory
   void pushPack(pack Package)
   {
	if (call PacketStorage.isFull())
      		call PacketStorage.popfront(); 
	
	call PacketStorage.pushback(Package);
   }

   void findNeighbor() 
   {
	//dbg(GENERAL_CHANNEL, "The discoverNeighborList for Node %d has been activated... \n", TOS_NODE_ID);
   	pack  NeighborPack;
	char* message = "this is a test\n";
	//Age all NeighborList first if list is not empty
	//dbg(GENERAL_CHANNEL, "Discovery activated: %d checking list for neighbors\n", TOS_NODE_ID);
	LSP_Limit++;
	if(!call NeighborStorage.isEmpty()) {
		uint16_t sizeofLink = call NeighborStorage.size();
		uint16_t i = 0;
		uint16_t pings = 0;
		LinkedNeighbor temp;
		LinkedNeighbor NeighborNode;
		//dbg(GENERAL_CHANNEL, "Or crash here...\n");
		
		//Increment the NumofPings because we are going through all of the neighbors in NeighborStorage
		//We drop off any neighbors that have been there for too long, one of the ways to prevent network congestion. Number 7 is picked to acheive this
		for(i = 0; i < sizeofLink; i++) {
			temp = call NeighborStorage.get(i);
			temp.NumofPings = temp.NumofPings + 1;
			pings = temp.NumofPings;
			if(pings > 7) 
			{
				NeighborNode = call NeighborStorage.removefromList(i);
				//dbg(NEIGHBOR_CHANNEL, "Node %d dropped due to more than 7 pings\n", NeighborNode.Node);
				call NeighborsDropped.pushfront(NeighborNode);
				i--;
				sizeofLink--;
			}
		}
	}

	//dbg(NEIGHBOR_CHANNEL, "Does it crash here... sendPackage: d%\n", &sendPackage);
	//We're read to ping packet to NeighborStorage
   	makePack(&NeighborPack, TOS_NODE_ID, AM_BROADCAST_ADDR, 2, PROTOCOL_PING, 1, (uint8_t*) message, (uint8_t) sizeof(message));

	//dbg(NEIGHBOR_CHANNEL, "What about crahh here...\n");
	pushPack(NeighborPack);
	call Sender.send(NeighborPack, AM_BROADCAST_ADDR);
   }

   void findRoute()
   {
   	//dbg(GENERAL_CHANNEL, "The routeTable Function for Node %d has been activated... \n", TOS_NODE_ID);
        pack RoutedNeighborPack;
 
       	//Check to first see if the routing table is empty. if so, we fill it with neighbors neighrbor list is empty or not
       	
	if(!call NeighborStorage.isEmpty()) 
	{	
        	uint16_t i = 0;
		LinkedNeighbor temp;
	        uint8_t sizeofLink = (call NeighborStorage.size()) + 1;
        	uint8_t neighbors [sizeofLink];

		//dbg(ROUTING_CHANNEL, "Node: %d Has successfully made an array of size: %d \n", TOS_NODE_ID, (sizeof(neighbors) / sizeof (uint8_t) - 1));
		//dbg(GENERAL_CHANNEL, "Or crash here...\n");
                
        	for(i = 0; i < sizeofLink; i++) 
		{
			temp = call NeighborStorage.get(i);
			neighbors[i] = temp.Node_ID;
			//i++;
			//neighbors[i] = TOS_NODE_ID; 
		}
        	
		neighbors[sizeofLink] = 0;
		makePack(&RoutedNeighborPack, TOS_NODE_ID, AM_BROADCAST_ADDR, MAX_TTL - 1, PROTOCOL_LINKSTATE, ++sequence, (uint8_t*) neighbors, (uint8_t) sizeof(neighbors));
       		pushPack(RoutedNeighborPack);
       		call Sender.send(RoutedNeighborPack, AM_BROADCAST_ADDR);	
		
		//dbg(ROUTING_CHANNEL, "Node: %d Has successfully sent out an LSP Packet! \n", TOS_NODE_ID);
	}

	else
		dbg(ROUTING_CHANNEL, "Node: %d currently has no neighbors! \n", TOS_NODE_ID);

   }
	
} //henlo
